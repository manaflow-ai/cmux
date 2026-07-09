public import Foundation
public import CmuxCore

/// Synchronous JSON-RPC client for a cmuxd-remote daemon over one of three
/// transports: `ssh ... <remotePath> serve --stdio` (newline-delimited JSON on
/// stdio), an SSH local forward to the baked VM daemon socket, or a brokered
/// WebSocket endpoint (faithful lift of the app target's
/// `WorkspaceRemoteDaemonRPCClient`).
///
/// Wire behavior is pinned: JSON payload keys, the `hello` capability
/// handshake, framing (one JSON object per `\n`-terminated line, optional
/// trailing `\r` stripped), stderr buffering/truncation, every NSError
/// domain/code/message, and all timeout constants must not change.
///
/// Isolation design (two serial queues + blocking semaphores, deliberately
/// not an actor):
/// - **Who mutates:** all transport state (`process`, pipes/handles,
///   websocket task/session/delegate, `isClosed`, `shouldReportTermination`,
///   `stdoutBuffer`, `stderrBuffer`, and both subscription maps) is confined
///   to `stateQueue`; readability/termination/receive callbacks hop onto it
///   with `stateQueue.async`, and synchronous paths enter with
///   `stateQueue.sync`.
/// - **Who reads:** RPC callers run on arbitrary threads; they serialize
///   frame writes through `writeQueue.sync` and then block on the pending
///   call's semaphore in ``RemoteDaemonPendingCallRegistry`` until the
///   transport reader resolves it. These blocking critical sections are
///   load-bearing: the synchronous call contract is what the proxy tunnel
///   and PTY bridge are built on, and actor reentrancy would reorder the
///   resolve-vs-timeout and stop-vs-write races the queues settle today.
/// - **Event delivery:** subscription handlers are invoked via
///   `subscription.queue.async` on the queue the caller registered,
///   preserving the legacy callback-queue contract.
/// - Async/await migration of this client is a deliberate later-phase item
///   (plan: "Modernization hot-spots (migrate in a later phase)").
public final class RemoteDaemonRPCClient: @unchecked Sendable {
    // @unchecked Sendable: every mutable property is confined to `stateQueue`
    // (see the isolation essay above); `writeQueue` serializes payload
    // writes; the registry is itself Sendable.

    static let maxStdoutBufferBytes = 256 * 1024
    static let bakedVMDaemonSocketPath = "/run/cmuxd-remote.sock"
    static let socketForwardStartupGracePeriod: TimeInterval = 0.75
    static let webSocketKeepaliveInterval: TimeInterval = 5.0
    /// Wire capability required for push-based proxy streaming
    /// (`proxy.stream.push`; value is test-pinned, do not change).
    public static let requiredProxyStreamCapability = RemoteDaemonCapability.proxyStreamPush.rawValue
    /// Wire capability required for persistent PTY sessions (`pty.session`;
    /// value is test-pinned, do not change).
    public static let requiredPTYSessionCapability = RemoteDaemonCapability.ptySession.rawValue
    /// Wire capability required for tokenized PTY attachments
    /// (`pty.session.token`; value is test-pinned, do not change).
    public static let requiredPTYSessionTokenCapability = RemoteDaemonCapability.ptySessionToken.rawValue
    /// Wire capability required for persistent-daemon PTY sessions
    /// (`pty.session.persistent_daemon`; value is test-pinned, do not change).
    public static let requiredPTYPersistentDaemonCapability = RemoteDaemonCapability.ptyPersistentDaemon.rawValue
    /// Wire capability required for write acknowledgement notifications
    /// (`pty.write.notification`; value is test-pinned, do not change).
    public static let requiredPTYWriteNotificationCapability = RemoteDaemonCapability.ptyWriteNotification.rawValue
    /// Wire capability required for resize notifications
    /// (`pty.resize.notification`; value is test-pinned, do not change).
    public static let requiredPTYResizeNotificationCapability = RemoteDaemonCapability.ptyResizeNotification.rawValue
    static let maxCloudCLIRequestsInFlight = 4

    // Subscription records pair the caller's delivery queue with its handler.
    // @unchecked Sendable: the handler is only ever invoked via
    // `queue.async` on the queue stored beside it (the legacy
    // callback-queue contract); the record itself is confined to stateQueue.
    struct StreamSubscription: @unchecked Sendable {
        let queue: DispatchQueue
        let handler: (RemoteDaemonStreamEvent) -> Void
    }

    // See StreamSubscription for the @unchecked Sendable justification.
    struct PTYSubscription: @unchecked Sendable {
        let queue: DispatchQueue
        let handler: (RemoteDaemonPTYEvent) -> Void
    }

    let configuration: WorkspaceRemoteConfiguration
    let remotePath: String
    let strings: RemoteDaemonStrings
    let cliRequestHandler: (@Sendable (Data) throws -> Data)?
    let keepaliveInterval: TimeInterval
    let keepaliveTimeout: TimeInterval
    /// Test seam: replaces the `/usr/bin/ssh` stdio-transport executable.
    /// Kept off the public initializer so the package API carries no
    /// test-injection surface; keepalive tests set it via `@testable import`
    /// before calling ``start()``. Production always launches `/usr/bin/ssh`.
    var transportExecutableOverride: String?
    let onUnexpectedTermination: (String) -> Void
    let transportKeepaliveQueue = DispatchQueue(label: "com.cmux.remote-ssh.daemon-rpc.keepalive.\(UUID().uuidString)")
    let writeQueue = DispatchQueue(label: "com.cmux.remote-ssh.daemon-rpc.write.\(UUID().uuidString)")
    let stateQueue = DispatchQueue(label: "com.cmux.remote-ssh.daemon-rpc.state.\(UUID().uuidString)")
    let cliRequestQueue = DispatchQueue(label: "com.cmux.remote-ssh.daemon-rpc.cli.\(UUID().uuidString)", qos: .utility, attributes: .concurrent)
    let pendingCalls = RemoteDaemonPendingCallRegistry()

    var process: Process?
    var stdinPipe: Pipe?
    var stdoutPipe: Pipe?
    var stderrPipe: Pipe?
    var stdinHandle: FileHandle?
    var stdoutHandle: FileHandle?
    var stderrHandle: FileHandle?
    var webSocketSession: URLSession?
    var webSocketTask: URLSessionWebSocketTask?
    var webSocketDelegate: RemoteDaemonWebSocketDelegate?
    var webSocketKeepaliveTimer: (any DispatchSourceTimer)?
    var webSocketKeepaliveTimeoutWorkItem: DispatchWorkItem?
    var webSocketKeepaliveInFlight = false
    var transportKeepaliveTimer: (any DispatchSourceTimer)?
    var transportKeepaliveTimeoutWorkItem: DispatchWorkItem?
    var transportKeepaliveInFlight = false
    var lastInboundFrameAt: DispatchTime = .now()
    var isClosed = true
    var shouldReportTermination = true

    var stdoutBuffer = Data()
    var stderrBuffer = ""
    var streamSubscriptions: [String: StreamSubscription] = [:]
    var ptySubscriptions: [String: PTYSubscription] = [:]
    var cliRequestsInFlight = 0

    /// Creates a client for one daemon transport.
    ///
    /// - Parameters:
    ///   - configuration: The remote connection this daemon serves.
    ///   - remotePath: Remote path of the cmuxd-remote binary (stdio
    ///     transport only).
    ///   - strings: App-bundle-resolved user-facing error strings (the
    ///     package never localizes).
    ///   - onUnexpectedTermination: Invoked (off the caller's queue) when the
    ///     transport dies without ``stop()``; payload is the best stderr
    ///     line or an exit-status description.
    public init(
        configuration: WorkspaceRemoteConfiguration,
        remotePath: String,
        strings: RemoteDaemonStrings,
        cliRequestHandler: (@Sendable (Data) throws -> Data)? = nil,
        keepaliveInterval: TimeInterval = 5.0,
        keepaliveTimeout: TimeInterval = 10.0,
        onUnexpectedTermination: @escaping (String) -> Void
    ) {
        self.configuration = configuration
        self.remotePath = remotePath
        self.strings = strings
        self.cliRequestHandler = cliRequestHandler
        self.keepaliveInterval = keepaliveInterval
        self.keepaliveTimeout = keepaliveTimeout
        self.onUnexpectedTermination = onUnexpectedTermination
    }

    /// Starts the transport for `configuration` and performs the `hello`
    /// capability handshake, throwing (and tearing the transport back down)
    /// when required capabilities are missing.
    public func start() throws {
        pendingCalls.reset()

        if configuration.daemonWebSocketEndpoint != nil {
            try startViaWebSocket()
        } else if Self.usesSocketForwardTransport(configuration: configuration) {
            try startViaBakedVMSocketForward()
            markTransportOpen()
        } else {
            try startViaSSHExec()
            markTransportOpen()
        }

        do {
            let hello = try call(method: "hello", params: [:], timeout: 8.0)
            let capabilities = (hello["capabilities"] as? [String]) ?? []
            let missingCapabilities = Self.missingRequiredCapabilities(
                Self.requiredCapabilities(for: configuration),
                in: capabilities
            )
            guard missingCapabilities.isEmpty else {
                throw NSError(domain: "cmux.remote.daemon.rpc", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: strings.missingRequiredCapabilitiesMessage(missingCapabilities),
                ])
            }
            if configuration.transport != .websocket {
                startTransportKeepalive()
            }
        } catch {
            stop(suppressTerminationCallback: true)
            throw error
        }
    }

    /// The daemon capabilities a connection with `configuration` requires:
    /// always proxy streaming, plus the persistent-PTY family when sessions
    /// outlive their terminal, plus the persistent-daemon capability when a
    /// slot is configured.
    public static func requiredCapabilities(for configuration: WorkspaceRemoteConfiguration) -> [String] {
        var capabilities = [requiredProxyStreamCapability]
        if configuration.preserveAfterTerminalExit {
            capabilities.append(requiredPTYSessionCapability)
            capabilities.append(requiredPTYSessionTokenCapability)
            capabilities.append(requiredPTYWriteNotificationCapability)
            capabilities.append(requiredPTYResizeNotificationCapability)
        }
        if configuration.persistentDaemonSlot != nil {
            capabilities.append(requiredPTYPersistentDaemonCapability)
        }
        return capabilities
    }

    /// The subset of `required` that `capabilities` does not advertise,
    /// preserving `required`'s order.
    public static func missingRequiredCapabilities(_ required: [String], in capabilities: [String]) -> [String] {
        let advertised = Set(capabilities)
        return required.filter { !advertised.contains($0) }
    }

    /// Stops the transport without reporting an unexpected termination.
    public func stop() {
        stop(suppressTerminationCallback: true)
    }

    func markTransportOpen() {
        stateQueue.sync {
            self.markTransportOpenLocked()
        }
    }

    func markTransportOpenLocked() {
        isClosed = false
        shouldReportTermination = true
        stdoutBuffer = Data()
        stderrBuffer = ""
        streamSubscriptions.removeAll(keepingCapacity: false)
        ptySubscriptions.removeAll(keepingCapacity: false)
    }

    func failPTYSubscriptionsLocked(_ detail: String) {
        let subscriptions = Array(ptySubscriptions.values)
        ptySubscriptions.removeAll(keepingCapacity: false)
        for subscription in subscriptions {
            subscription.queue.async {
                subscription.handler(.error(detail))
            }
        }
    }

    func stop(suppressTerminationCallback: Bool) {
        let captured: (Process?, FileHandle?, FileHandle?, FileHandle?, URLSessionWebSocketTask?, URLSession?, Bool, String) = stateQueue.sync {
            let detail = Self.bestErrorLine(stderr: stderrBuffer) ?? "daemon transport stopped"
            let shouldNotify = !suppressTerminationCallback && !isClosed
            shouldReportTermination = !suppressTerminationCallback
            if isClosed {
                return (nil, nil, nil, nil, nil, nil, false, detail)
            }

            isClosed = true
            signalPendingFailureLocked("daemon transport stopped")
            let capturedProcess = process
            let capturedStdin = stdinHandle
            let capturedStdout = stdoutHandle
            let capturedStderr = stderrHandle
            let capturedWebSocketTask = webSocketTask
            let capturedWebSocketSession = webSocketSession

            stopWebSocketKeepaliveLocked()
            stopTransportKeepaliveLocked()
            process = nil
            stdinPipe = nil
            stdoutPipe = nil
            stderrPipe = nil
            stdinHandle = nil
            stdoutHandle = nil
            stderrHandle = nil
            webSocketTask = nil
            webSocketSession = nil
            webSocketDelegate = nil
            streamSubscriptions.removeAll(keepingCapacity: false)
            failPTYSubscriptionsLocked(detail)
            return (
                capturedProcess,
                capturedStdin,
                capturedStdout,
                capturedStderr,
                capturedWebSocketTask,
                capturedWebSocketSession,
                shouldNotify,
                detail
            )
        }

        captured.2?.readabilityHandler = nil
        captured.3?.readabilityHandler = nil
        try? captured.1?.close()
        try? captured.2?.close()
        try? captured.3?.close()
        if let process = captured.0, process.isRunning {
            process.terminate()
        }
        captured.4?.cancel(with: .normalClosure, reason: nil)
        captured.5?.invalidateAndCancel()
        if captured.6 {
            onUnexpectedTermination(captured.7)
        }
    }

    func signalPendingFailureLocked(_ message: String) {
        pendingCalls.failAll(message)
    }
}

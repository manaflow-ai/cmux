import Foundation
import NIOCore
import NIOSSH
import NIOTransportServices

/// Result of a non-interactive command.
public struct SSHExecResult: Sendable, Equatable {
    public var stdout: Data
    public var stderr: Data
    /// `nil` when the server closed without reporting a status.
    public var exitStatus: Int?

    public var stdoutString: String { String(decoding: stdout, as: UTF8.self) }
    public var stderrString: String { String(decoding: stderr, as: UTF8.self) }
}

/// One authenticated SSH connection. Many channels (shells, exec, forwards,
/// SFTP) multiplex over it.
///
/// Transport is Network.framework through NIOTransportServices, so iOS path
/// changes surface as connection closure rather than silent stalls. A
/// connection can also ride inside another connection's direct-tcpip channel,
/// which is how jump hosts (ProxyJump) work.
public actor SSHConnection {
    public nonisolated let endpoint: SSHEndpoint
    /// The server identity key accepted during the handshake.
    public nonisolated let hostKey: SSHHostKey
    private let channel: any Channel
    private let sshHandler: NIOSSHHandler

    private init(endpoint: SSHEndpoint, hostKey: SSHHostKey, channel: any Channel, sshHandler: NIOSSHHandler) {
        self.endpoint = endpoint
        self.hostKey = hostKey
        self.channel = channel
        self.sshHandler = sshHandler
    }

    /// The event loop this connection's transport runs on.
    nonisolated var eventLoop: any EventLoop { channel.eventLoop }

    /// Future that completes when the connection closes.
    public nonisolated var closeFuture: EventLoopFuture<Void> { channel.closeFuture }

    /// Connects and authenticates.
    ///
    /// - Parameters:
    ///   - via: an already-open connection to tunnel through (jump host).
    ///   - connectTimeout: TCP + handshake budget.
    public static func connect(
        to endpoint: SSHEndpoint,
        credentials: [SSHCredential],
        hostKeyVerifier: any SSHHostKeyVerifier,
        via jump: SSHConnection? = nil,
        connectTimeout: TimeAmount = .seconds(15)
    ) async throws -> SSHConnection {
        let authDelegate = SSHCredentialAuthDelegate(username: endpoint.username, credentials: credentials)

        // The SSH handler must be in the pipeline before the first inbound
        // byte: servers send their version line the moment they accept, and
        // a line that reaches an empty pipeline is dropped, stalling the
        // handshake until the timeout. So it is installed by the transport's
        // channel initializer, never after the connect returns.
        let eventLoop: any EventLoop = jump?.eventLoop ?? NIOTSEventLoopGroup.singleton.next()
        let handshake = eventLoop.makePromise(of: Void.self)
        // Network phases spend this budget; host key verification, which can
        // wait on a trust prompt, pauses it (see SSHHostKeyAuthDelegate).
        let deadline = SSHHandshakeDeadline(timeout: connectTimeout, eventLoop: eventLoop)
        let hostKeyDelegate = SSHHostKeyAuthDelegate(endpoint: endpoint, verifier: hostKeyVerifier, deadline: deadline)
        deadline.complete(with: handshake.futureResult)
        let installSSH: @Sendable (any Channel) -> EventLoopFuture<Void> = { channel in
            channel.eventLoop.makeCompletedFuture {
                try channel.pipeline.syncOperations.addHandlers(
                    NIOSSHHandler(
                        role: .client(SSHClientConfiguration(userAuthDelegate: authDelegate, serverAuthDelegate: hostKeyDelegate)),
                        allocator: channel.allocator,
                        inboundChildChannelInitializer: nil
                    ),
                    SSHHandshakeObserver(promise: handshake)
                )
            }
        }

        let channel: any Channel
        let sshHandler: NIOSSHHandler
        do {
            if let jump {
                channel = try await jump.openDirectTCPIP(host: endpoint.host, port: endpoint.port) { child in
                    child.pipeline.addHandler(SSHChannelDataUnwrapper()).flatMap { installSSH(child) }
                }
            } else {
                channel = try await NIOTSConnectionBootstrap(group: eventLoop)
                    .connectTimeout(connectTimeout)
                    .channelOption(NIOTSChannelOptions.waitForActivity, value: false)
                    .channelInitializer(installSSH)
                    .connect(host: endpoint.host, port: endpoint.port)
                    .get()
            }
            sshHandler = try await channel.pipeline.handler(type: NIOSSHHandler.self).get()
        } catch {
            // No channel (or no handler) means the observer never ran.
            handshake.fail(error)
            throw error
        }
        do {
            try await deadline.futureResult.get()
        } catch {
            // Closing fails the still-pending handshake through its observer.
            try? await channel.close()
            // The verifier's decision wins over however the transport
            // reported the aborted handshake (error, close, or timeout).
            if await hostKeyDelegate.rejectedPresentedKey, let key = await hostKeyDelegate.presentedKey {
                throw SSHConnectionError.hostKeyRejected(.unknown(presented: key))
            }
            throw error
        }
        guard let hostKey = await hostKeyDelegate.presentedKey else {
            try? await channel.close()
            throw SSHConnectionError.closed
        }
        return SSHConnection(endpoint: endpoint, hostKey: hostKey, channel: channel, sshHandler: sshHandler)
    }

    /// Closes the connection and every channel on it.
    public func close() async {
        try? await channel.close()
    }

    // MARK: - Session channels

    /// Opens a session channel, optionally with a PTY, then starts `command`
    /// (`exec`), a login shell (`nil`), or a subsystem such as `sftp`.
    public func openSession(
        pty: SSHPTYRequest? = nil,
        environment: [String: String] = [:],
        start: SSHSessionStart
    ) async throws -> SSHSessionChannel {
        let (stream, continuation) = AsyncStream<SSHSessionEvent>.makeStream(bufferingPolicy: .unbounded)
        let sessionHandler = SSHSessionChannelHandler(continuation: continuation)
        let child = try await createChannel(type: .session) { child in
            child.pipeline.addHandler(sessionHandler)
        }
        let context = try await child.pipeline.context(handler: sessionHandler).get()
        try await child.eventLoop.flatSubmit { () -> EventLoopFuture<Void> in
            var chain = child.eventLoop.makeSucceededVoidFuture()
            for (name, value) in environment.sorted(by: { $0.key < $1.key }) {
                // Servers commonly refuse env vars (AcceptEnv); treat as best effort.
                chain = chain.flatMap {
                    sessionHandler.sendRequest(
                        SSHChannelRequestEvent.EnvironmentRequest(wantReply: true, name: name, value: value),
                        label: "env",
                        context: context
                    ).recover { _ in }
                }
            }
            if let pty {
                chain = chain.flatMap {
                    sessionHandler.sendRequest(
                        SSHChannelRequestEvent.PseudoTerminalRequest(
                            wantReply: true,
                            term: pty.term,
                            terminalCharacterWidth: pty.columns,
                            terminalRowHeight: pty.rows,
                            terminalPixelWidth: pty.pixelWidth,
                            terminalPixelHeight: pty.pixelHeight,
                            terminalModes: SSHTerminalModes([:])
                        ),
                        label: "pty-req",
                        context: context
                    )
                }
            }
            return chain.flatMap {
                switch start {
                case .shell:
                    sessionHandler.sendRequest(SSHChannelRequestEvent.ShellRequest(wantReply: true), label: "shell", context: context)
                case .exec(let command):
                    sessionHandler.sendRequest(SSHChannelRequestEvent.ExecRequest(command: command, wantReply: true), label: "exec", context: context)
                case .subsystem(let name):
                    sessionHandler.sendRequest(SSHChannelRequestEvent.SubsystemRequest(subsystem: name, wantReply: true), label: "subsystem", context: context)
                }
            }
        }.get()
        return SSHSessionChannel(channel: child, events: stream)
    }

    /// Runs a command to completion and collects its output.
    public func exec(_ command: String, stdin: Data? = nil) async throws -> SSHExecResult {
        let session = try await openSession(start: .exec(command))
        if let stdin {
            try await session.write(stdin)
            try await session.sendEOF()
        }
        var result = SSHExecResult(stdout: Data(), stderr: Data(), exitStatus: nil)
        for await event in session.events {
            switch event {
            case .stdout(let data): result.stdout.append(data)
            case .stderr(let data): result.stderr.append(data)
            case .exitStatus(let status): result.exitStatus = status
            case .exitSignal: result.exitStatus = result.exitStatus ?? -1
            case .closed: break
            }
        }
        return result
    }

    // MARK: - Forwarding

    /// Opens a `direct-tcpip` channel to `host:port` as seen from the server.
    /// The returned channel carries `SSHChannelData`; `initializer` installs
    /// handlers (e.g. an unwrapper to plain bytes).
    public func openDirectTCPIP(
        host: String,
        port: Int,
        initializer: @escaping @Sendable (any Channel) -> EventLoopFuture<Void>
    ) async throws -> any Channel {
        let originator = try SocketAddress(ipAddress: "127.0.0.1", port: 0)
        let type = SSHChannelType.DirectTCPIP(targetHost: host, targetPort: port, originatorAddress: originator)
        return try await createChannel(type: .directTCPIP(type), initializer: initializer)
    }

    private func createChannel(
        type: SSHChannelType,
        initializer: @escaping @Sendable (any Channel) -> EventLoopFuture<Void>
    ) async throws -> any Channel {
        let sshHandler = sshHandler
        let channel = channel
        return try await channel.eventLoop.flatSubmit { () -> EventLoopFuture<any Channel> in
            let promise = channel.eventLoop.makePromise(of: (any Channel).self)
            sshHandler.createChannel(promise, channelType: type) { child, openedType in
                guard openedType == type else {
                    return child.eventLoop.makeFailedFuture(SSHConnectionError.channelOpenFailed("\(openedType)"))
                }
                return initializer(child)
            }
            return promise.futureResult
        }.get()
    }
}

/// How a session channel starts after optional pty/env requests.
public enum SSHSessionStart: Sendable, Equatable {
    case shell
    case exec(String)
    case subsystem(String)
}

/// Completes the handshake promise once user authentication succeeds, or
/// fails it when the connection errors or closes first.
private final class SSHHandshakeObserver: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = Any
    private var promise: EventLoopPromise<Void>?

    init(promise: EventLoopPromise<Void>) {
        self.promise = promise
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is UserAuthSuccessEvent {
            promise?.succeed(())
            promise = nil
        }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        promise?.fail(error)
        promise = nil
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        promise?.fail(SSHConnectionError.closed)
        promise = nil
        context.fireChannelInactive()
    }
}

/// Converts `SSHChannelData` to plain `ByteBuffer`s and back, so a
/// direct-tcpip channel can act as a byte transport (jump hosts, forwards).
final class SSHChannelDataUnwrapper: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = SSHChannelData

    func handlerAdded(context: ChannelHandlerContext) {
        _ = context.channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let message = unwrapInboundIn(data)
        guard case .channel = message.type, case .byteBuffer(let buffer) = message.data else { return }
        context.fireChannelRead(wrapInboundOut(buffer))
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let buffer = unwrapOutboundIn(data)
        context.write(wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(buffer))), promise: promise)
    }
}

/// The handshake's time budget, confined to the channel's event loop.
///
/// Network phases (version exchange, key exchange, authentication) spend it.
/// Host key verification may wait on the user, so it pauses the budget and
/// the remainder is re-armed when verification ends. Pauses nest.
final class SSHHandshakeDeadline: @unchecked Sendable {
    private let eventLoop: any EventLoop
    private let timeout: TimeAmount
    private let promise: EventLoopPromise<Void>
    // Event-loop confined.
    private var remaining: TimeAmount
    private var armedAt: NIODeadline?
    private var timer: Scheduled<Void>?
    private var pauses = 0
    private var finished = false

    init(timeout: TimeAmount, eventLoop: any EventLoop) {
        self.eventLoop = eventLoop
        self.timeout = timeout
        remaining = timeout
        promise = eventLoop.makePromise(of: Void.self)
        onLoop { $0.arm() }
    }

    /// Succeeds or fails with the watched work, or fails with
    /// `ChannelError.connectTimeout` once the unpaused budget runs out.
    var futureResult: EventLoopFuture<Void> { promise.futureResult }

    /// The work this deadline bounds.
    func complete(with work: EventLoopFuture<Void>) {
        work.whenComplete { [self] result in onLoop { $0.finish(result) } }
    }

    /// Stops the clock, keeping the unspent budget.
    func pause() {
        onLoop { deadline in
            guard !deadline.finished else { return }
            deadline.pauses += 1
            guard deadline.pauses == 1 else { return }
            deadline.timer?.cancel()
            deadline.timer = nil
            if let armedAt = deadline.armedAt {
                deadline.remaining = max(.zero, deadline.remaining - (deadline.eventLoop.now - armedAt))
            }
            deadline.armedAt = nil
        }
    }

    /// Restarts the clock with the unspent budget once every pause ended.
    func resume() {
        onLoop { deadline in
            guard !deadline.finished, deadline.pauses > 0 else { return }
            deadline.pauses -= 1
            if deadline.pauses == 0 { deadline.arm() }
        }
    }

    private func arm() {
        guard !finished, pauses == 0 else { return }
        armedAt = eventLoop.now
        timer = eventLoop.scheduleTask(in: remaining) { [self] in
            finish(.failure(ChannelError.connectTimeout(timeout)))
        }
    }

    private func finish(_ result: Result<Void, any Error>) {
        guard !finished else { return }
        finished = true
        timer?.cancel()
        timer = nil
        promise.completeWith(result)
    }

    private func onLoop(_ body: @escaping @Sendable (SSHHandshakeDeadline) -> Void) {
        if eventLoop.inEventLoop {
            body(self)
        } else {
            eventLoop.execute { body(self) }
        }
    }
}

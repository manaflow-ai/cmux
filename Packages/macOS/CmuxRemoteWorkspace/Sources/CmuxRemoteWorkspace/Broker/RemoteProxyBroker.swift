public import CmuxCore
public import Dispatch
internal import Darwin
internal import Foundation

/// Shares one daemon proxy tunnel per remote transport across all subscribers.
/// Each subscriber holds a ``RemoteProxyLease``; the entry restarts its tunnel
/// with exponential backoff until the last lease is released.
///
/// The app injects one instance into each remote session controller.
/// Isolation design: every mutable property (`entries` and the per-entry
/// state) is confined to the private serial `queue`. Mutators are the public
/// API (caller threads bridged with the legacy blocking `queue.sync`,
/// load-bearing because session controllers need synchronous results and the
/// initial `acquire` update must be delivered before it returns), lease
/// releases (hopped onto `queue`), tunnel failure callbacks (hopped onto
/// `queue`), and restart-backoff task wakeups. An actor would make synchronous
/// `acquire`/PTY contracts impossible without semaphores. `@unchecked Sendable` because `@Sendable` restart tasks and
/// tunnel callbacks capture `self`; queue confinement is the safety argument.
///
/// Deliberate delta from the legacy broker: the restart backoff used
/// `queue.asyncAfter` + `DispatchWorkItem`; it is now an injected-clock
/// `Task` (``RemoteProxyRetryClock``) whose wakeup is guarded by a per-entry
/// restart token, so cancellation plus the token guard absorb every stale
/// fire the legacy `cancel()` covered. Delays are identical (whole seconds,
/// converted to milliseconds exactly).
public final class RemoteProxyBroker: @unchecked Sendable {
    private final class Entry {
        let configuration: WorkspaceRemoteConfiguration
        var remotePath: String
        var tunnel: (any RemoteProxyTunneling)?
        var endpoint: BrowserProxyEndpoint?
        var restartTask: Task<Void, Never>?
        var restartToken: UUID?
        var restartRetryCount = 0
        var ptyLifecycleSnapshot: RemotePTYLifecycleSnapshot?
        var subscribers: [UUID: @Sendable (RemoteProxyBrokerUpdate) -> Void] = [:]

        init(configuration: WorkspaceRemoteConfiguration, remotePath: String) {
            self.configuration = configuration
            self.remotePath = remotePath
        }
    }

    private let tunnelProvider: any RemoteProxyTunnelProviding
    private let clock: any RemoteProxyRetryClock
    private let queue = DispatchQueue(label: "com.cmux.remote-ssh.proxy-broker", qos: .utility)
    private var entries: [String: Entry] = [:]
    private var ptyLifecycleOwners: [RemotePTYLifecycleKey: (transportKey: String, attachmentKey: RemotePTYAttachmentKey)] = [:]
    internal private(set) var currentPTYLifecycleByAttachment: [RemotePTYAttachmentKey: RemotePTYLifecycleKey] = [:]

    /// Creates a broker.
    ///
    /// - Parameters:
    ///   - tunnelProvider: Factory for per-transport tunnels (production:
    ///     ``RemoteDaemonProxyTunnelProvider``).
    ///   - clock: Sleep seam driving the restart backoff (production
    ///     default: the continuous clock).
    public init(
        tunnelProvider: any RemoteProxyTunnelProviding,
        clock: any RemoteProxyRetryClock = SystemRemoteProxyRetryClock()
    ) {
        self.tunnelProvider = tunnelProvider
        self.clock = clock
    }

    /// Subscribes to the shared tunnel for `configuration`; see
    /// ``RemoteProxyBrokering/acquire(configuration:remotePath:onUpdate:)``.
    public func acquire(
        configuration: WorkspaceRemoteConfiguration,
        remotePath: String,
        onUpdate: @escaping @Sendable (RemoteProxyBrokerUpdate) -> Void
    ) -> RemoteProxyLease {
        queue.sync {
            let key = Self.transportKey(for: configuration)
            let subscriberID = UUID()
            let entry: Entry
            if let existing = entries[key] {
                entry = existing
                if existing.remotePath != remotePath {
                    existing.remotePath = remotePath
                    existing.restartRetryCount = 0
                    if existing.tunnel != nil {
                        stopEntryRuntimeLocked(existing, preservePTYLifecycle: true)
                        notifyLocked(existing, update: .connecting)
                    }
                }
            } else {
                entry = Entry(configuration: configuration, remotePath: remotePath)
                entries[key] = entry
            }

            entry.subscribers[subscriberID] = onUpdate
            if let endpoint = entry.endpoint {
                onUpdate(.ready(endpoint))
            } else {
                onUpdate(.connecting)
            }

            if entry.tunnel == nil, entry.restartTask == nil {
                startEntryLocked(key: key, entry: entry)
            }

            return RemoteProxyLease(key: key, subscriberID: subscriberID, broker: self)
        }
    }

    /// Lists persistent PTY sessions through the ready tunnel.
    public func listPTY(configuration: WorkspaceRemoteConfiguration) throws -> [[String: Any]] {
        try withReadyTunnel(configuration: configuration) { tunnel in
            try tunnel.listPTY()
        }
    }

    /// Closes a persistent PTY session through the ready tunnel.
    ///
    /// The broker queue is used only to retain the tunnel; the potentially
    /// blocking cleanup runs after that queue is released.
    ///
    /// - Parameters:
    ///   - configuration: Remote transport whose ready tunnel owns the PTY.
    ///   - sessionID: Persistent PTY session to terminate.
    ///   - deadline: Monotonic deadline shared with the originating cleanup call.
    public func closePTY(
        configuration: WorkspaceRemoteConfiguration,
        sessionID: String,
        deadline: DispatchTime
    ) throws {
        let tunnel = try queue.sync {
            let key = Self.transportKey(for: configuration)
            guard let tunnel = entries[key]?.tunnel else { throw Self.ptyTunnelNotReadyError() }
            return tunnel
        }
        try tunnel.closePTY(sessionID: sessionID, deadline: deadline)
    }

    /// Returns the shared lifecycle for one logical PTY attach generation.
    public func ptySessionLifecycle(
        configuration: WorkspaceRemoteConfiguration,
        sessionID: String,
        lifecycleID: String
    ) throws -> RemotePTYSessionLifecycle {
        try queue.sync {
            let key = Self.transportKey(for: configuration)
            guard let entry = entries[key] else { throw Self.ptyTunnelNotReadyError() }
            if let tunnel = entry.tunnel {
                return tunnel.ptySessionLifecycle(sessionID: sessionID, lifecycleID: lifecycleID)
            }
            guard let snapshot = entry.ptyLifecycleSnapshot else { throw Self.ptyTunnelNotReadyError() }
            return snapshot.ptySessionLifecycle(sessionID: sessionID, lifecycleID: lifecycleID)
        }
    }

    /// Retires one logical PTY attach generation in either the live tunnel or
    /// the snapshot retained while an automatic replacement is pending.
    public func acknowledgePTYLifecycle(
        configuration: WorkspaceRemoteConfiguration,
        sessionID: String,
        lifecycleID: String
    ) throws {
        try queue.sync {
            let key = Self.transportKey(for: configuration)
            guard let entry = entries[key] else {
                throw NSError(domain: "cmux.remote.pty", code: 40, userInfo: [
                    NSLocalizedDescriptionKey: "remote daemon tunnel is not ready",
                ])
            }
            if let tunnel = entry.tunnel {
                tunnel.acknowledgePTYLifecycle(sessionID: sessionID, lifecycleID: lifecycleID)
            } else if var snapshot = entry.ptyLifecycleSnapshot {
                snapshot.acknowledgePTYLifecycle(sessionID: sessionID, lifecycleID: lifecycleID)
                entry.ptyLifecycleSnapshot = snapshot
            } else {
                throw Self.ptyTunnelNotReadyError()
            }
            ptyLifecycleOwners.removeValue(
                forKey: RemotePTYLifecycleKey(sessionID: sessionID, lifecycleID: lifecycleID)
            )
        }
    }
    /// Claims a generation and enqueues retirement against its exact transport.
    @discardableResult
    public func acknowledgePTYLifecycleAfterWrapperEnd(sessionID: String, lifecycleID: String) -> Bool {
        let lifecycleKey = RemotePTYLifecycleKey(sessionID: sessionID, lifecycleID: lifecycleID)
        let ownership = queue.sync { () -> (transportKey: String, wasCurrent: Bool)? in
            guard let owner = ptyLifecycleOwners.removeValue(forKey: lifecycleKey) else { return nil }
            let wasCurrent = currentPTYLifecycleByAttachment[owner.attachmentKey] == lifecycleKey
            if wasCurrent { currentPTYLifecycleByAttachment.removeValue(forKey: owner.attachmentKey) }
            return (owner.transportKey, wasCurrent)
        }
        guard let ownership else { return false }
        queue.async { [weak self] in
            guard let self, let entry = self.entries[ownership.transportKey] else { return }
            if let tunnel = entry.tunnel {
                _ = tunnel.acknowledgePTYLifecycleIfKnown(
                    sessionID: lifecycleKey.sessionID,
                    lifecycleID: lifecycleKey.lifecycleID
                )
            } else if var snapshot = entry.ptyLifecycleSnapshot,
                      snapshot.acknowledgePTYLifecycleIfKnown(
                        sessionID: lifecycleKey.sessionID,
                        lifecycleID: lifecycleKey.lifecycleID
                      ) {
                entry.ptyLifecycleSnapshot = snapshot
            }
        }
        return ownership.wasCurrent
    }

    /// Resizes a PTY attachment through the ready tunnel.
    public func resizePTY(
        configuration: WorkspaceRemoteConfiguration,
        sessionID: String,
        attachmentID: String,
        attachmentToken: String,
        cols: Int,
        rows: Int
    ) throws {
        try withReadyTunnel(configuration: configuration) { tunnel in
            try tunnel.resizePTY(
                sessionID: sessionID,
                attachmentID: attachmentID,
                attachmentToken: attachmentToken,
                cols: cols,
                rows: rows
            )
        }
    }

    /// Detaches a PTY attachment through the ready tunnel.
    public func detachPTY(
        configuration: WorkspaceRemoteConfiguration,
        sessionID: String,
        attachmentID: String,
        attachmentToken: String
    ) throws {
        try withReadyTunnel(configuration: configuration) { tunnel in
            try tunnel.detachPTY(
                sessionID: sessionID,
                attachmentID: attachmentID,
                attachmentToken: attachmentToken
            )
        }
    }

    /// Starts a loopback PTY bridge through the ready tunnel.
    public func startPTYBridge(
        configuration: WorkspaceRemoteConfiguration,
        sessionID: String,
        lifecycleID: String,
        attachmentID: String,
        command: String?,
        requireExisting: Bool
    ) throws -> RemotePTYBridgeServer.Endpoint {
        try queue.sync {
            let ownerKey = Self.transportKey(for: configuration)
            guard let tunnel = entries[ownerKey]?.tunnel else { throw Self.ptyTunnelNotReadyError() }
            let lifecycleKey = RemotePTYLifecycleKey(sessionID: sessionID, lifecycleID: lifecycleID)
            let attachmentKey = RemotePTYAttachmentKey(transportKey: ownerKey, attachmentID: attachmentID)
            let endpoint = try tunnel.startPTYBridge(
                sessionID: sessionID,
                lifecycleID: lifecycleID,
                attachmentID: attachmentID,
                command: command,
                requireExisting: requireExisting
            ) { [weak self] in
                guard let self else { return }
                self.queue.async {
                    guard self.ptyLifecycleOwners[lifecycleKey]?.transportKey == ownerKey else { return }
                    self.ptyLifecycleOwners.removeValue(forKey: lifecycleKey)
                    if self.currentPTYLifecycleByAttachment[attachmentKey] == lifecycleKey {
                        self.currentPTYLifecycleByAttachment.removeValue(forKey: attachmentKey)
                    }
                }
            }
            ptyLifecycleOwners[lifecycleKey] = (ownerKey, attachmentKey)
            currentPTYLifecycleByAttachment[attachmentKey] = lifecycleKey
            return endpoint
        }
    }

    private func withReadyTunnel<T>(
        configuration: WorkspaceRemoteConfiguration,
        _ body: (any RemoteProxyTunneling) throws -> T
    ) throws -> T {
        try queue.sync {
            let key = Self.transportKey(for: configuration)
            guard let entry = entries[key], let tunnel = entry.tunnel else {
                throw Self.ptyTunnelNotReadyError()
            }
            return try body(tunnel)
        }
    }

    internal func release(key: String, subscriberID: UUID) {
        queue.async { [weak self] in
            guard let self, let entry = self.entries[key] else { return }
            entry.subscribers.removeValue(forKey: subscriberID)
            guard entry.subscribers.isEmpty else { return }
            self.teardownEntryLocked(key: key, entry: entry)
        }
    }

    private func startEntryLocked(key: String, entry: Entry) {
        cancelRestartLocked(entry)

        let localPort: Int
        if let forcedLocalPort = entry.configuration.localProxyPort {
            // Internal deterministic test hook used by docker regressions to force bind conflicts.
            localPort = forcedLocalPort
        } else {
            let retryDelay = Self.retryDelay(baseDelay: 3.0, retry: entry.restartRetryCount + 1)
            guard let allocatedPort = Self.allocateLoopbackPort() else {
                notifyLocked(
                    entry,
                    update: .error("Failed to allocate local proxy port\(Self.retrySuffix(delay: retryDelay))")
                )
                scheduleRestartLocked(key: key, entry: entry, baseDelay: 3.0)
                return
            }
            localPort = allocatedPort
        }

        do {
            let tunnel = tunnelProvider.makeTunnel(
                configuration: entry.configuration,
                remotePath: entry.remotePath,
                localPort: localPort
            ) { [weak self] detail in
                guard let self else { return }
                self.queue.async {
                    self.handleTunnelFailureLocked(key: key, detail: detail)
                }
            }
            if let snapshot = entry.ptyLifecycleSnapshot {
                tunnel.restorePTYLifecycle(snapshot)
            }
            try tunnel.start()
            entry.tunnel = tunnel
            entry.ptyLifecycleSnapshot = nil
            let endpoint = BrowserProxyEndpoint(host: "127.0.0.1", port: localPort)
            entry.endpoint = endpoint
            entry.restartRetryCount = 0
            notifyLocked(entry, update: .ready(endpoint))
        } catch {
            stopEntryRuntimeLocked(entry, preservePTYLifecycle: true)
            let detail = "Failed to start local daemon proxy: \(error.localizedDescription)"
            let retryDelay = Self.retryDelay(baseDelay: 3.0, retry: entry.restartRetryCount + 1)
            notifyLocked(entry, update: .error("\(detail)\(Self.retrySuffix(delay: retryDelay))"))
            scheduleRestartLocked(key: key, entry: entry, baseDelay: 3.0)
        }
    }

    private func handleTunnelFailureLocked(key: String, detail: String) {
        guard let entry = entries[key], entry.tunnel != nil else { return }
        stopEntryRuntimeLocked(entry, preservePTYLifecycle: true)
        let retryDelay = Self.retryDelay(baseDelay: 3.0, retry: entry.restartRetryCount + 1)
        notifyLocked(entry, update: .error("\(detail)\(Self.retrySuffix(delay: retryDelay))"))
        scheduleRestartLocked(key: key, entry: entry, baseDelay: 3.0)
    }

    private func scheduleRestartLocked(key: String, entry: Entry, baseDelay: TimeInterval) {
        guard !entry.subscribers.isEmpty else {
            teardownEntryLocked(key: key, entry: entry)
            return
        }
        guard entry.restartTask == nil else { return }
        entry.restartRetryCount += 1
        let retryDelay = Self.retryDelay(baseDelay: baseDelay, retry: entry.restartRetryCount)
        // Whole-second legacy delays convert exactly; round up so the delay
        // can never undershoot the legacy deadline.
        let milliseconds = Int((retryDelay * 1000).rounded(.up))

        let token = UUID()
        entry.restartToken = token
        // Cancellation is absorbed by guards, not checks: a cancelled sleep
        // throws (no wakeup), and a stale post-sleep wakeup fails the token
        // guard in `restartDelayElapsed` because every cancel/start path
        // clears or replaces the token first.
        entry.restartTask = Task { [weak self] in
            guard let self else { return }
            guard (try? await self.clock.sleep(forMilliseconds: milliseconds)) != nil else { return }
            self.queue.async {
                self.restartDelayElapsed(key: key, token: token)
            }
        }
    }

    /// Runs on `queue` after a restart backoff; the token guard drops stale
    /// wakeups from entries that were torn down, restarted, or replaced.
    private func restartDelayElapsed(key: String, token: UUID) {
        guard let entry = entries[key], entry.restartToken == token else { return }
        entry.restartTask = nil
        entry.restartToken = nil
        guard !entry.subscribers.isEmpty else {
            teardownEntryLocked(key: key, entry: entry)
            return
        }
        notifyLocked(entry, update: .connecting)
        startEntryLocked(key: key, entry: entry)
    }

    private func cancelRestartLocked(_ entry: Entry) {
        entry.restartTask?.cancel()
        entry.restartTask = nil
        entry.restartToken = nil
    }

    private func teardownEntryLocked(key: String, entry: Entry) {
        cancelRestartLocked(entry)
        stopEntryRuntimeLocked(entry, preservePTYLifecycle: false)
        entries.removeValue(forKey: key)
        ptyLifecycleOwners = ptyLifecycleOwners.filter { $0.value.transportKey != key }
        currentPTYLifecycleByAttachment = currentPTYLifecycleByAttachment.filter { $0.key.transportKey != key }
    }

    private func stopEntryRuntimeLocked(_ entry: Entry, preservePTYLifecycle: Bool) {
        if preservePTYLifecycle {
            if let tunnel = entry.tunnel {
                entry.ptyLifecycleSnapshot = tunnel.stopPreservingPTYLifecycle()
            }
        } else {
            entry.ptyLifecycleSnapshot = nil
            entry.tunnel?.stop()
        }
        entry.tunnel = nil
        entry.endpoint = nil
    }

    private func notifyLocked(_ entry: Entry, update: RemoteProxyBrokerUpdate) {
        for callback in entry.subscribers.values {
            callback(update)
        }
    }

    private static func transportKey(for configuration: WorkspaceRemoteConfiguration) -> String {
        configuration.proxyBrokerTransportKey
    }

    private static func ptyTunnelNotReadyError() -> NSError {
        NSError(domain: "cmux.remote.pty", code: 40, userInfo: [
            NSLocalizedDescriptionKey: "remote daemon tunnel is not ready",
        ])
    }

    /// Binds an ephemeral loopback TCP socket to discover a free port (pure
    /// Darwin socket utility; no broker state).
    private static func allocateLoopbackPort() -> Int? {
        for _ in 0..<8 {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { return nil }
            defer { close(fd) }

            var yes: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = in_port_t(0)
            addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

            let bindResult = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    bind(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bindResult == 0 else { continue }

            var bound = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let nameResult = withUnsafeMutablePointer(to: &bound) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    getsockname(fd, sockaddrPtr, &len)
                }
            }
            guard nameResult == 0 else { continue }

            let port = Int(UInt16(bigEndian: bound.sin_port))
            if port > 0 && port <= 65535 {
                return port
            }
        }
        return nil
    }

    private static func retrySuffix(delay: TimeInterval) -> String {
        let seconds = max(1, Int(delay.rounded()))
        return " (retry in \(seconds)s)"
    }

    private static func retryDelay(baseDelay: TimeInterval, retry: Int) -> TimeInterval {
        let exponent = Double(max(0, retry - 1))
        return min(baseDelay * pow(2.0, exponent), 60.0)
    }
}

/// The protocol conformance lives with the type; the surface is identical.
extension RemoteProxyBroker: RemoteProxyBrokering {}

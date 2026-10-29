public import CmuxNextWakeups
public import Foundation
import os

/// One Cloud machine's headless `cmux-tui remote connect` link. The link
/// dials the machine's daemon (`ws://<vpc-ip>:1337/v1/link`, trusted
/// carrier) through the WireGuard hub and exposes a local Unix socket that
/// speaks the same v12 protocol as the local daemon, so the App connects a
/// `DaemonConnection` to it and attaches terminals over it unchanged.
///
/// ``socketPath()`` is the connection's endpoint provider: it returns the
/// live socket, or (re)starts the link: fresh attach endpoint, hub socket,
/// spawn, first `connection-snapshot` within the deadline. A dead link is
/// replaced on the next call, which the connection makes on reconnect.
/// Its later snapshots drive ``redial`` while the client redials (cx-z5oif). R-hop: each ``redial`` change is
/// one visible task posted on the app's scheduler, in the order the link reports them.
public actor CloudMachineLink {
    /// The queue this actor runs on (threading-model.md, `com.cmuxterm.next.cloud.machine-link`): its socket and binary checks block a thread of
    /// its own, never a cooperative pool thread (the HomeCache pattern).
    // executor: com.cmuxterm.next.cloud.machine-link
    private nonisolated let queue = DispatchSerialQueue(label: "com.cmuxterm.next.cloud.machine-link", qos: .userInitiated)

    /// Runs the actor on ``queue``.
    public nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    public nonisolated let machineID: String
    /// Whether the running link redials, from its later snapshots.
    public nonisolated let redial = CloudLinkRedial()
    /// The app's main-thread scheduler: ``redial`` changes are posted on it.
    private nonisolated let mainWork: MainWorkScheduler
    private let api: CloudAPIClient
    private let hub: CloudTunnelHub
    private let paths: CloudPaths
    private let binary: URL
    private let deviceName: String
    private var child: ChildProcess?
    private var socket: String?
    private var starting: Task<String, any Error>?
    private var stopped = false
    private var suspended = false
    private var generation = 0
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "cloud.link")

    /// `mainWork` is the app's one main-thread scheduler (``redial`` lives on the main actor).
    public init(machineID: String, api: CloudAPIClient, hub: CloudTunnelHub, paths: CloudPaths, binary: URL, deviceName: String,
                mainWork: MainWorkScheduler) {
        self.machineID = machineID
        self.mainWork = mainWork
        self.api = api
        self.hub = hub
        self.paths = paths
        self.binary = binary
        self.deviceName = deviceName
    }

    public func socketPath() async throws -> String {
        let generation = generation
        try checkGeneration(generation)
        if let socket, child?.isRunning == true, FileManager.default.fileExists(atPath: socket) { return socket }
        if let starting {
            let path = try await starting.value
            try checkGeneration(generation)
            return path
        }
        let task = Task { try await self.start(generation: generation) }
        starting = task
        defer { if self.generation == generation { starting = nil } }
        let path = try await task.value
        try checkGeneration(generation)
        return path
    }

    /// Ends the link for good (machine removed, sign-out, quit).
    public func stop() {
        stopped = true
        invalidate()
    }

    private func invalidate() {
        generation += 1
        starting?.cancel()
        starting = nil
        child?.terminate()
        child = nil
        socket = nil
        clearRedial()
    }

    /// Parks the link while its machine is paused. Unlike `stop`, parking is
    /// reversible: a later resume can start a fresh attach endpoint and socket
    /// on the same session.
    public func suspend() {
        guard !stopped else { return }
        suspended = true
        invalidate()
    }

    /// Allows a new connection after the provider reports the machine live.
    public func resume() {
        guard !stopped else { return }
        suspended = false
    }

    private func checkGeneration(_ generation: Int) throws {
        try Task.checkCancellation()
        guard !stopped, !suspended, self.generation == generation else { throw CancellationError() }
    }

    /// PID of the running link process, for diagnostics.
    public var pid: Int32? { child?.pid }

    private func start(generation: Int) async throws -> String {
        try checkGeneration(generation)
        child?.terminate()
        child = nil
        socket = nil
        try paths.prepare()
        let deviceFingerprint = paths.loadLinkDeviceFingerprint(machineID: machineID)
        // Lifecycle transitions can run during every await. A stale start
        // must never publish a socket or replace a newer link.
        let endpoint = try await api.attachEndpoint(machineID, deviceFingerprint: deviceFingerprint)
        try checkGeneration(generation)
        let hubSocket = try await hub.socketPath()
        try checkGeneration(generation)
        unlink(paths.linkSocket(machineID: machineID))
        let inviteFile = endpoint.invitation.map { _ in
            paths.linkState.appendingPathComponent("invite-\(UUID().uuidString.lowercased())")
        }
        if let invitation = endpoint.invitation, let inviteFile {
            try paths.writeSecret(invitation.uri + "\n", to: inviteFile)
        }
        defer {
            if let inviteFile { try? FileManager.default.removeItem(at: inviteFile) }
        }
        var arguments = [
            "remote", "connect", endpoint.route,
            "--device-name", deviceName,
            "--state-dir", paths.linkState.path,
            "--local-socket", paths.linkSocket(machineID: machineID),
            "--headless", "--json", "--exit-with-parent", "--lanes", "single",
            "--connect-timeout-seconds", "20",
        ]
        if let inviteFile {
            arguments += ["--invite-file", inviteFile.path]
        } else if endpoint.trustedCarrier {
            arguments.append("--carrier")
        }
        arguments += ["--wireguard-hub", hubSocket]
        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_REMOTE_STATE_DIR"] = paths.linkState.path
        guard FileManager.default.isExecutableFile(atPath: binary.path) else { throw ChildProcessError.missingBinary(binary.path) }
        let child = ChildProcess(executable: binary, arguments: arguments, environment: environment)
        try await child.start()
        do {
            // A stop or suspend during the launch found no child to end.
            try checkGeneration(generation)
        } catch {
            child.terminate()
            throw error
        }
        self.child = child
        do {
            let socketTask = Task {
                try await child.firstLine(within: .seconds(60), label: "cmux-tui remote connect") { line in
                    if case .connected(let socket) = CloudLinkEvent.parse(line) { return socket }
                    return nil
                }
            }
            defer { socketTask.cancel() }
            if let invitation = endpoint.invitation {
                let approval = try await api.approveCmuxRemoteEnrollment(machineID, invitationID: invitation.invitationId)
                guard approval.approved, approval.state == "approved" || approval.state == "already_enrolled" else {
                    socketTask.cancel()
                    throw CloudAPIError.decoding("/api/vm/\(machineID)/cmux-remote/approve")
                }
                if let fingerprint = approval.deviceFingerprint, !fingerprint.isEmpty {
                    try paths.writeSecret(fingerprint + "\n", to: paths.linkDeviceFingerprint(machineID: machineID))
                }
            }
            let path = try await socketTask.value
            try checkGeneration(generation)
            self.socket = path
            postRedialing(false)
            watchSnapshots(child)
            logger.info("link up for \(self.machineID, privacy: .public) pid \(child.pid ?? 0)")
            return path
        } catch {
            if endpoint.invitation == nil, !endpoint.trustedCarrier, deviceFingerprint != nil {
                // The local hint may name an enrollment revoked or absent on
                // this machine. The next retry mints a fresh invitation.
                paths.clearLinkDeviceFingerprint(machineID: machineID)
            }
            child.terminate()
            if self.child === child { self.child = nil }
            logger.error("link for \(self.machineID, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            throw error
        }
    }

    /// The running link client redials on its own after sleep, a network
    /// drop or change, and its local socket stays up meanwhile; only its
    /// snapshots say so. The machine reads as reconnecting until it is back.
    private func watchSnapshots(_ child: ChildProcess) {
        let lines = child.lines
        // task-owner: ends with the child's stdout
        Task { [weak self] in
            for await line in lines {
                guard let connected = CloudLinkEvent.linkConnected(line) else { continue }
                await self?.linkReported(child, connected: connected)
            }
        }
    }

    private func linkReported(_ reporting: ChildProcess, connected: Bool) async {
        guard child === reporting else { return }
        postRedialing(!connected)
    }

    /// A teardown: no running link redials.
    private func clearRedial() {
        postRedialing(false)
    }

    /// Posts `redialing` to ``redial`` as one visible task: the machine's sidebar row and status read it.
    private nonisolated func postRedialing(_ redialing: Bool) {
        let redial = redial
        mainWork.postFromAnyThread(.visible, owner: Self.redialOwner) { redial.isRedialing = redialing }
    }

    /// The redial posts' owner in the board and the wakeup ledger.
    private static let redialOwner = "CloudMachineLink.redial"
}

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
/// Its later snapshots drive ``redial`` while the client redials (cx-z5oif).
public actor CloudMachineLink {
    public nonisolated let machineID: String
    /// Whether the running link redials, from its later snapshots.
    public nonisolated let redial = CloudLinkRedial()
    /// ``callerOwnsVM`` for the main actor (Settings > Machines' row), on the same link.
    public nonisolated let ownership = CloudLinkOwnership()
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
    /// The running link's attach answer said the signed-in caller owns the machine; false once
    /// that link ends (``callerOwnsVM``).
    private var linkOwnsVM = false
    /// Counts links: each link start and end takes a new one (``ownerLink``).
    private var linkID = 0
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "cloud.link")

    public init(machineID: String, api: CloudAPIClient, hub: CloudTunnelHub, paths: CloudPaths, binary: URL, deviceName: String) {
        self.machineID = machineID
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
        setOwnsVM(false)
        clearRedial()
    }

    /// A link started or ended: its ``callerOwnsVM`` under a new ``ownerLink`` id, here and on
    /// ``ownership`` (which drops a hop that arrives after a newer one).
    private func setOwnsVM(_ owns: Bool) {
        linkID += 1
        linkOwnsVM = owns
        let (ownership, link) = (ownership, linkID)
        // task-owner: one main-actor hop
        Task { @MainActor in ownership.publish(owns, link: link) }
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

    /// `--vm-kind owner` when this attach's answer said the signed-in caller owns the machine
    /// (``CloudAttachEndpoint/callerOwnsVM``), else nothing. Asked again at each link start and
    /// never saved: the link's acpmux peer bridge leases the machine at the VM boundary only for
    /// this link (cmux-tui `remote_cli/acpmux_peer.rs`).
    public static func vmKindArguments(_ endpoint: CloudAttachEndpoint) -> [String] {
        endpoint.callerOwnsVM ? ["--vm-kind", "owner"] : []
    }

    /// Whether the running link's attach answer said the signed-in caller owns the machine
    /// (``CloudAttachEndpoint/callerOwnsVM``): an app-started chat there sends `vm_kind: "owner"`
    /// (cmux-tui `agent-session-start`). False while no link runs; never saved past the link.
    public var callerOwnsVM: Bool {
        guard socket != nil, child?.isRunning == true else { return false }
        return linkOwnsVM
    }

    /// The running link's id while ``callerOwnsVM``, else nil. A start reads it before it
    /// connects and again as it sends: a different answer means the link ended or came up again
    /// (with the Cloud API asked again), so an owner answer never carries over to another link.
    public var ownerLink: Int? { callerOwnsVM ? linkID : nil }

    /// PID of the running link process, for diagnostics.
    public var pid: Int32? { child?.pid }

    private func start(generation: Int) async throws -> String {
        try checkGeneration(generation)
        child?.terminate()
        child = nil
        socket = nil
        setOwnsVM(false)
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
        let arguments = Self.connectArguments(route: endpoint.route, deviceName: deviceName, paths: paths, machineID: machineID,
                                              inviteFile: inviteFile, trustedCarrier: endpoint.trustedCarrier, hubSocket: hubSocket,
                                              vmKind: Self.vmKindArguments(endpoint))
        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_REMOTE_STATE_DIR"] = paths.linkState.path
        guard FileManager.default.isExecutableFile(atPath: binary.path) else { throw ChildProcessError.missingBinary(binary.path) }
        let child = ChildProcess(executable: binary, arguments: arguments, environment: environment)
        try child.start()
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
            setOwnsVM(endpoint.callerOwnsVM)
            let redial = redial
            await MainActor.run { redial.isRedialing = false }
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

    /// The `cmux-tui remote connect` argv of one link. `--lanes auto` gives keystrokes their own
    /// WebSocket, apart from control and from bulk and tunnel bytes (terminal output, forwarded
    /// browser ports): on one carrier a key waited behind every bulk frame already in its TCP send
    /// buffer (#25595). Later links of an invited link enroll with the device the first one enrolled.
    static func connectArguments(route: String, deviceName: String, paths: CloudPaths, machineID: String,
                                 inviteFile: URL?, trustedCarrier: Bool, hubSocket: String, vmKind: [String] = []) -> [String] {
        var arguments = [
            "remote", "connect", route,
            "--device-name", deviceName,
            "--state-dir", paths.linkState.path,
            "--local-socket", paths.linkSocket(machineID: machineID),
            "--headless", "--json", "--exit-with-parent", "--lanes", "auto",
            "--connect-timeout-seconds", "20",
        ]
        if let inviteFile {
            arguments += ["--invite-file", inviteFile.path]
        } else if trustedCarrier {
            arguments.append("--carrier")
        }
        return arguments + vmKind + ["--wireguard-hub", hubSocket]
    }

    /// The running link client redials on its own after sleep, a network
    /// drop or change, and its local socket stays up meanwhile; only its
    /// snapshots say so. The machine reads as reconnecting until it is back.
    /// Its stdout closing means it ended: its owner answer ends with it.
    private func watchSnapshots(_ child: ChildProcess) {
        let lines = child.lines
        // task-owner: ends with the child's stdout
        Task { [weak self] in
            for await line in lines {
                guard let connected = CloudLinkEvent.linkConnected(line) else { continue }
                await self?.linkReported(child, connected: connected)
            }
            await self?.linkEnded(child)
        }
    }

    private func linkEnded(_ ended: ChildProcess) {
        guard child === ended else { return }
        setOwnsVM(false)
    }

    private func linkReported(_ reporting: ChildProcess, connected: Bool) async {
        guard child === reporting else { return }
        let redial = redial
        await MainActor.run { redial.isRedialing = !connected }
    }

    /// A teardown: no running link redials.
    private func clearRedial() {
        let redial = redial
        // task-owner: one main-actor hop
        Task { @MainActor in redial.isRedialing = false }
    }
}

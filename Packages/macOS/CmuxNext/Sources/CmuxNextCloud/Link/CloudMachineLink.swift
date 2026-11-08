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
    /// The start's step and its last failure (``CloudLinkProgress``): what a start that did not come
    /// up says, and whether waiting on it can still help.
    public nonisolated let progress = CloudLinkProgress()
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
    /// The running link's attach answer said the machine is a teammate's (``callerIsTeammate``).
    private var linkIsTeammate = false
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
        progress.ended()
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
    private func setOwnsVM(_ owns: Bool, teammate: Bool = false) {
        linkID += 1
        linkOwnsVM = owns
        linkIsTeammate = teammate && !owns
        let (ownership, link) = (ownership, linkID)
        // task-owner: one main-actor hop
        Task { @MainActor in ownership.publish(owns, link: link) }
    }

    /// Ends the running link so the next ``socketPath()`` starts a fresh one, which asks the Cloud
    /// API again for its attach answer (a chat share just made the caller the machine's `owner`).
    /// The connection on it reconnects as after any dropped link. A stopped link stays stopped.
    public func renew() {
        guard !stopped else { return }
        invalidate()
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
        CloudStartCore().vmKind(endpoint.vmKind).linkArguments
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

    /// True while a link runs and its attach answer said the machine is a teammate's
    /// (``CloudAttachEndpoint/callerIsTeammate``): a chat start is refused as a teammate's machine.
    /// It never grants a start; only ``ownerLink`` does.
    public var callerIsTeammate: Bool {
        guard socket != nil, child?.isRunning == true else { return false }
        return linkIsTeammate
    }

    /// The running link process's pid while ``callerOwnsVM``, else nil: Move to Cloud sends the
    /// owner word with it (`--to-pid`), so only a connection this process serves carries it.
    public var ownerPID: Int32? { callerOwnsVM ? child?.pid : nil }

    /// PID of the running link process, for diagnostics.
    public var pid: Int32? { child?.pid }

    /// One start: every step has a deadline and a log line (``CloudLinkStep``), and a failure, the
    /// step's or its deadline's, is logged with the step and kept in ``progress``, so a start never
    /// waits silently (2026-11-02: a nightly's Cloud chat start waited 3 minutes with no line).
    private func start(generation: Int) async throws -> String {
        let began = ContinuousClock.now
        logger.notice("link start for \(self.machineID, privacy: .public)")
        do {
            let path = try await startSteps(generation: generation)
            progress.succeeded()
            logger.notice("link up for \(self.machineID, privacy: .public) in \(Self.seconds(since: began), privacy: .public)")
            return path
        } catch is CancellationError {
            progress.ended()
            logger.notice("link start for \(self.machineID, privacy: .public) ended (superseded) after \(Self.seconds(since: began), privacy: .public)")
            throw CancellationError()
        } catch {
            let failure = CloudLinkStartError(step: progress.snapshot.step ?? .remoteConnect, error: error)
            progress.failed(failure)
            logger.error("link for \(self.machineID, privacy: .public) failed at \(failure.step.rawValue, privacy: .public) after \(Self.seconds(since: began), privacy: .public): \(failure.reason, privacy: .public)")
            throw failure
        }
    }

    static func seconds(since instant: ContinuousClock.Instant) -> String {
        let elapsed = instant.duration(to: .now)
        return String(format: "%.1f s", Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18)
    }

    /// Runs `step` under its deadline with a began/done log line.
    private func step<T: Sendable>(_ step: CloudLinkStep, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        progress.began(step)
        let began = ContinuousClock.now
        logger.notice("link \(self.machineID, privacy: .public): \(step.rawValue, privacy: .public) began")
        let value = try await runLinkStep(step, work)
        logger.notice("link \(self.machineID, privacy: .public): \(step.rawValue, privacy: .public) done in \(Self.seconds(since: began), privacy: .public)")
        return value
    }

    private func startSteps(generation: Int) async throws -> String {
        try checkGeneration(generation)
        child?.terminate()
        child = nil
        socket = nil
        setOwnsVM(false)
        try paths.prepare()
        let deviceFingerprint = paths.loadLinkDeviceFingerprint(machineID: machineID)
        // Lifecycle transitions can run during every await. A stale start
        // must never publish a socket or replace a newer link.
        let (api, hub, machineID) = (api, hub, machineID)
        let endpoint = try await step(.attachEndpoint) { try await api.attachEndpoint(machineID, deviceFingerprint: deviceFingerprint) }
        try checkGeneration(generation)
        let hubEndpoint = try await step(.hub) { try await hub.endpoint() }
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
        arguments += Self.vmKindArguments(endpoint)
        arguments += ["--wireguard-hub", hubEndpoint.socket, "--wireguard-hub-token-stdin"]
        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_REMOTE_STATE_DIR"] = paths.linkState.path
        progress.began(.remoteConnect)
        guard FileManager.default.isExecutableFile(atPath: binary.path) else { throw ChildProcessError.missingBinary(binary.path) }
        let child = ChildProcess(executable: binary, arguments: arguments, environment: environment,
                                 input: Data((hubEndpoint.clientToken + "\n").utf8))
        try child.start()
        self.child = child
        logger.notice("link \(self.machineID, privacy: .public): remote-connect spawned pid \(child.pid ?? 0)")
        do {
            let socketTask = Task {
                try await child.firstLine(within: .seconds(60), label: "cmux-tui remote connect") { line in
                    if case .connected(let socket) = CloudLinkEvent.parse(line) { return socket }
                    return nil
                }
            }
            defer { socketTask.cancel() }
            if let invitation = endpoint.invitation {
                let approval = try await step(.approve) { try await api.approveCmuxRemoteEnrollment(machineID, invitationID: invitation.invitationId) }
                guard approval.approved, approval.state == "approved" || approval.state == "already_enrolled" else {
                    socketTask.cancel()
                    throw CloudAPIError.decoding("/api/vm/\(machineID)/cmux-remote/approve")
                }
                progress.began(.remoteConnect)
                if let fingerprint = approval.deviceFingerprint, !fingerprint.isEmpty {
                    try paths.writeSecret(fingerprint + "\n", to: paths.linkDeviceFingerprint(machineID: machineID))
                }
            }
            let path = try await socketTask.value
            try checkGeneration(generation)
            self.socket = path
            setOwnsVM(endpoint.callerOwnsVM, teammate: endpoint.callerIsTeammate)
            let redial = redial
            await MainActor.run { redial.isRedialing = false }
            watchSnapshots(child)
            logger.notice("link \(self.machineID, privacy: .public): remote-connect up, pid \(child.pid ?? 0)")
            return path
        } catch {
            if endpoint.invitation == nil, !endpoint.trustedCarrier, deviceFingerprint != nil {
                // The local hint may name an enrollment revoked or absent on
                // this machine. The next retry mints a fresh invitation.
                paths.clearLinkDeviceFingerprint(machineID: machineID)
            }
            child.terminate()
            if self.child === child { self.child = nil }
            throw error
        }
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

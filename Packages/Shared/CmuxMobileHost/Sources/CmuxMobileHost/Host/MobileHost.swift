import CmuxLink
import CmuxMobileLink
import CmuxMobileWire
import Foundation

/// The Mac side of `cmux.mobile/1` (b5-mac-host.md): accepts `CmuxLink`
/// sessions from a carrier's `LinkAcceptor`, admits paired devices, and
/// serves `rpc` and `terminal` channels against the daemon, plus the
/// pluggable browser, rd and files handlers. Owns no entity.
///
/// Single use: `stop()` is final (sign-out, account switch, quit). Make a
/// new host to serve again.
public actor MobileHost {
    public nonisolated let configuration: MobileHostConfiguration
    /// The `workspace:<host>` projection, shared with the `HostDO` uplink.
    public nonisolated let workspaceStream: WorkspaceStreamOwner
    /// The op path, shared with the `HostDO` uplink.
    public nonisolated let executor: MobileOpExecutor
    public nonisolated let authorizer: any MobileDeviceAuthorizer
    /// The `task:<host>` projection when a task runner is registered (C8).
    public nonisolated let taskStream: TaskStreamOwner?
    /// The task family, for the uplink's `read task.list`.
    nonisolated let tasks: MobileTaskService?

    private let linkHost: LinkHost
    private let context: MobileHostContext
    private let keyResolver: (any CarrierKeyResolver)?
    private var sessionsTask: Task<Void, Never>?
    private var revocationTask: Task<Void, Never>?
    private var servers: [ObjectIdentifier: MobileSessionServer] = [:]
    private var started = false
    private var stopped = false
    /// Bumped on each start/stop so an actor suspension during revocation
    /// setup cannot install a reader after the host has been closed.
    private var lifetime: UInt64 = 0

    public init(configuration: MobileHostConfiguration, acceptor: any LinkAcceptor, daemon: any MobileDaemon,
                authorizer: any MobileDeviceAuthorizer, handlers: MobileChannelHandlers = MobileChannelHandlers(),
                linkConfiguration: LinkConfiguration = LinkConfiguration(), clock: LinkClock = .continuous,
                workspaceStartSeq: UInt64? = nil, taskRunner: (any MobileTaskRunner)? = nil,
                taskAttachments: any MobileTaskAttachmentResolver = UnavailableTaskAttachments(),
                taskStartSeq: UInt64? = nil, keyResolver: (any CarrierKeyResolver)? = nil) {
        var configuration = configuration
        if taskRunner != nil {
            configuration.caps.append(MobileHostConfiguration.taskStreamCap)
            if configuration.allowsTaskDispatch { configuration.caps.append(MobileHostConfiguration.taskDispatchCap) }
        }
        self.configuration = configuration
        self.authorizer = authorizer
        self.keyResolver = keyResolver
        let owner = WorkspaceStreamOwner(hostID: configuration.hostID, daemon: daemon, startSeq: workspaceStartSeq)
        workspaceStream = owner
        let tasks = taskRunner.map { runner in
            MobileTaskService(
                owner: TaskStreamOwner(hostID: configuration.hostID, runner: runner, startSeq: taskStartSeq),
                runner: runner,
                policy: MobileTaskPolicy(hostID: configuration.hostID, allowsDispatch: configuration.allowsTaskDispatch),
                attachments: taskAttachments)
        }
        taskStream = tasks?.owner
        let executor = MobileOpExecutor(
            policy: MobileOpPolicy(hostID: configuration.hostID, allowsTerminalSpawn: configuration.allowsTerminalSpawn),
            owner: owner, daemon: daemon, authorizer: authorizer, tasks: tasks)
        self.executor = executor
        self.tasks = tasks
        linkHost = LinkHost(acceptor: acceptor, configuration: linkConfiguration, clock: clock)
        context = MobileHostContext(configuration: configuration, authorizer: authorizer, owner: owner,
                                    executor: executor, daemon: daemon, handlers: handlers, clock: clock, tasks: tasks)
    }

    /// Every stream this host serves, by name.
    nonisolated var streams: [String: any MobileStreamOwner] {
        var all: [String: any MobileStreamOwner] = [workspaceStream.stream: workspaceStream]
        if let taskStream { all[taskStream.stream] = taskStream }
        return all
    }

    /// Starts accepting sessions. Idempotent; no effect after `stop()`.
    public func start() async {
        guard !started, !stopped else { return }
        started = true
        lifetime &+= 1
        let run = lifetime
        let revocations = await authorizer.revocations()
        guard !stopped, run == lifetime else { return }
        revocationTask = Task { [weak self] in
            for await install in revocations {
                guard let self else { return }
                await self.revoke(install)
            }
        }
        await linkHost.start()
        guard !stopped, run == lifetime else {
            await linkHost.close()
            return
        }
        let sessions = await linkHost.sessions()
        guard !stopped, run == lifetime else {
            await linkHost.close()
            return
        }
        sessionsTask = Task { [weak self] in
            for await session in sessions {
                guard let self else { return }
                await self.serve(session)
            }
        }
    }

    /// Closes every session and stops accepting. Final.
    public func stop() async {
        guard !stopped else { return }
        stopped = true
        lifetime &+= 1
        sessionsTask?.cancel()
        revocationTask?.cancel()
        sessionsTask = nil
        revocationTask = nil
        await linkHost.close()
        await workspaceStream.stop()
        await taskStream?.stop()
        servers.removeAll()
    }

    /// Admitted devices with a live session (diagnostics, tests).
    public func connectedInstalls() async -> [String] {
        var installs: Set<String> = []
        for server in servers.values {
            if let install = await server.principal?.install { installs.insert(install) }
        }
        return installs.sorted()
    }

    // MARK: Private

    /// The carrier's authenticated peer becomes the hello's attestation
    /// (b5-mac-host.md 3): a proof for another install is refused.
    private func serve(_ session: LinkSession) async {
        guard !stopped else { return }
        let attestation = await CarrierAttestation.make(identity: await session.peerIdentity, resolver: keyResolver)
        guard !stopped else { return }
        // Registered before its hello, so a revocation during admission finds it.
        let server = MobileSessionServer(session: session, context: context, attestation: attestation)
        let id = ObjectIdentifier(server)
        servers[id] = server
        Task { [weak self] in
            await server.run()
            await self?.ended(id)
        }
    }

    private func ended(_ id: ObjectIdentifier) {
        servers[id] = nil
    }

    /// Revokes every session of `install` concurrently: one peer that stopped
    /// reading cannot delay another's revocation.
    private func revoke(_ install: String) async {
        let all = Array(servers.values)
        await withTaskGroup(of: Void.self) { group in
            for server in all {
                group.addTask { _ = await server.revokeIfMatches(install) }
            }
        }
    }
}

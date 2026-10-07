import CmuxLink
import CmuxMobileWire
import Foundation

/// The Mac side of `cmux.mobile/1` (b5-mac-host.md): accepts `CmuxLink`
/// sessions from a carrier's `LinkAcceptor`, admits paired devices, and
/// serves `rpc` and `terminal` channels against the daemon, plus the
/// pluggable browser, rd and files handlers. Owns no entity.
public actor MobileHost {
    public nonisolated let configuration: MobileHostConfiguration
    /// The `workspace:<host>` projection, shared with the `HostDO` uplink.
    public nonisolated let workspaceStream: WorkspaceStreamOwner
    /// The op path, shared with the `HostDO` uplink.
    public nonisolated let executor: MobileOpExecutor
    public nonisolated let authorizer: any MobileDeviceAuthorizer

    private let linkHost: LinkHost
    private let context: MobileHostContext
    private var sessionsTask: Task<Void, Never>?
    private var revocationTask: Task<Void, Never>?
    private var servers: [ObjectIdentifier: MobileSessionServer] = [:]
    private var admitted: [String: Set<ObjectIdentifier>] = [:]
    private var started = false

    public init(configuration: MobileHostConfiguration, acceptor: any LinkAcceptor, daemon: any MobileDaemon,
                authorizer: any MobileDeviceAuthorizer, handlers: MobileChannelHandlers = MobileChannelHandlers(),
                linkConfiguration: LinkConfiguration = LinkConfiguration(), clock: LinkClock = .continuous,
                workspaceStartSeq: UInt64? = nil) {
        self.configuration = configuration
        self.authorizer = authorizer
        let owner = WorkspaceStreamOwner(hostID: configuration.hostID, daemon: daemon, startSeq: workspaceStartSeq)
        workspaceStream = owner
        let executor = MobileOpExecutor(
            policy: MobileOpPolicy(hostID: configuration.hostID, allowsTerminalSpawn: configuration.allowsTerminalSpawn),
            owner: owner, daemon: daemon)
        self.executor = executor
        linkHost = LinkHost(acceptor: acceptor, configuration: linkConfiguration, clock: clock)
        let box = WeakHost()
        context = MobileHostContext(configuration: configuration, authorizer: authorizer, owner: owner,
                                    executor: executor, daemon: daemon, handlers: handlers,
                                    onAdmitted: { server, install in await box.host?.admit(server, install: install) })
        box.host = self
    }

    /// Starts accepting sessions. Idempotent.
    public func start() async {
        guard !started else { return }
        started = true
        await linkHost.start()
        let sessions = await linkHost.sessions()
        sessionsTask = Task { [weak self] in
            for await session in sessions {
                guard let self else { return }
                await self.serve(session)
            }
        }
        let revocations = await authorizer.revocations()
        revocationTask = Task { [weak self] in
            for await install in revocations {
                guard let self else { return }
                await self.revoke(install)
            }
        }
    }

    /// Closes every session and stops accepting (sign-out, account switch, quit).
    public func stop() async {
        sessionsTask?.cancel()
        revocationTask?.cancel()
        sessionsTask = nil
        revocationTask = nil
        await linkHost.close()
        await workspaceStream.stop()
        servers.removeAll()
        admitted.removeAll()
        started = false
    }

    /// Admitted devices with a live session (diagnostics, tests).
    public var connectedInstalls: [String] { admitted.filter { !$0.value.isEmpty }.keys.sorted() }

    // MARK: Private

    private func serve(_ session: LinkSession) {
        let server = MobileSessionServer(session: session, context: context)
        let id = ObjectIdentifier(server)
        servers[id] = server
        Task { [weak self] in
            await server.run()
            await self?.ended(id)
        }
    }

    private func admit(_ server: MobileSessionServer, install: String) {
        admitted[install, default: []].insert(ObjectIdentifier(server))
    }

    private func ended(_ id: ObjectIdentifier) {
        servers[id] = nil
        for install in admitted.keys { admitted[install]?.remove(id) }
    }

    private func revoke(_ install: String) async {
        let ids = admitted.removeValue(forKey: install) ?? []
        for id in ids { await servers[id]?.revoke() }
    }
}

/// Breaks the init-time cycle between the host and its context.
private final class WeakHost: @unchecked Sendable {
    weak var host: MobileHost?
}

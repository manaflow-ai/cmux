public import CmuxNextBrowser
import CmuxNextCompat
public import CmuxNextDaemon
public import CmuxNextDaemonService
import CmuxNextRemoteLocalhost
public import CmuxNextSettings
import CryptoKit
public import Foundation
import Observation
import os

/// Remote localhost for browser tabs: decides each tab's route and store,
/// owns the in-process proxy and one forwarding connection per machine.
/// Nothing starts until a tab of a remote machine needs it.
@MainActor
public final class RemoteLocalhostService {
    private let machines: any RemoteLocalhostMachines
    private let proxy = RemoteLocalhostProxy()
    private var clients: [ObjectIdentifier: LoopbackForwardClient] = [:]
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "remote-localhost")
    /// cmux.json `browser.remoteLocalhost*`, live.
    public var setting: RemoteLocalhostSetting = .fallback
    @ObservationIgnored private var observation: Task<Void, Never>?

    /// DEBUG builds: `CMUX_NEXT_REMOTE_LOCALHOST_DEBUG_SOCKET` names a second
    /// cmux-tui socket whose machine the tabs of this Mac use, so the
    /// Chromium path can be verified with a second local daemon. Nil in
    /// release builds.
    private let debugSocket: String?

    public init(machines: any RemoteLocalhostMachines, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.machines = machines
        #if DEBUG
        debugSocket = environment["CMUX_NEXT_REMOTE_LOCALHOST_DEBUG_SOCKET"].flatMap { $0.isEmpty ? nil : $0 }
        #else
        debugSocket = nil
        #endif
    }

    private static let debugMachineName = "debug-remote"

    public func follow(_ settings: SettingsController) {
        observation?.cancel()
        observation = Task { [weak self] in
            for await value in ObservationStream({ settings.snapshot.remoteLocalhost }) {
                self?.setting = value
            }
        }
    }

    // MARK: Routing

    /// The route of `tab` for `engine`. A page cannot influence it: it
    /// depends only on which daemon holds the tab, the settings and the
    /// daemon's capabilities.
    public func route(for tab: TabModel, engine: BrowserEngineKind) -> RemoteLocalhostRoute {
        let daemon = machines.daemon(forTab: tab)
        let workspace = daemon.store.pane(containing: tab.surface).flatMap { daemon.store.workspace(containing: $0.handle) }
        return route(daemon: daemon, workspace: workspace?.id, engine: engine)
    }

    /// The route of a tab of `daemon`'s workspace `workspace` for `engine`
    /// (also before the tab exists, for its notice).
    public func route(daemon: DaemonService, workspace: String?, engine: BrowserEngineKind) -> RemoteLocalhostRoute {
        if daemon.isLocal, debugSocket != nil {
            return engine == .cef ? .machine(Self.debugMachineName) : .thisMacInstead(Self.debugMachineName, .webKit)
        }
        guard !daemon.isLocal else { return .thisMac }
        let name = machineName(of: daemon)
        guard isEnabled(workspace: workspace) else { return .thisMacInstead(name, .turnedOff) }
        guard daemon.supports(DaemonCapability.loopbackForward.rawValue) else { return .thisMacInstead(name, .updateMachine) }
        guard engine == .cef else { return .thisMacInstead(name, .webKit) }
        return .machine(name)
    }

    /// Whether workspace `id` uses its machine's localhost: the person's
    /// own choice (personal state, `workspace.setRemoteLocalhost`) first,
    /// then cmux.json `browser.remoteLocalhost*`.
    public func isEnabled(workspace id: String?) -> Bool {
        if let id, let address = machines.personalAddress(ofWorkspace: id),
           let choice = machines.local.store.personal.workspace(session: address.session, key: address.key)?.remoteLocalhost {
            return choice
        }
        return setting.isEnabled(workspace: id)
    }

    /// `base` with the store and navigation guard for `tab` showing `url`:
    /// a loopback URL of a remote machine gets the derived store (its
    /// requests go through the proxy); any other URL of a remote tab keeps
    /// the profile's store and may not navigate to loopback, so this Mac's
    /// localhost is never reached silently. Nil when the proxy failed to
    /// start (the caller shows the failure instead of loading).
    public func configuration(for tab: TabModel, url: URL?, base: BrowserTabConfiguration) async -> BrowserTabConfiguration? {
        var configuration = base
        let route = route(for: tab, engine: .cef)
        let plan = RemoteLocalhostStorePlan.plan(route: route, url: url)
        if case .thisMac = route {} else {
            plans[tab.id] = "\(plan) \(url?.host(percentEncoded: false) ?? "-")"
            if plans.count > 256 { plans.removeAll() }
        }
        switch plan {
        case .profile(let guardMode):
            configuration.navigationGuard = guardMode
            return configuration
        case .derived:
            break
        }
        guard case .machine(let name) = route else { return configuration }
        let daemon = machines.daemon(forTab: tab)
        guard let registryID = daemon.isLocal ? debugSocket : daemon.store.registryID else { return nil }
        let key = Self.machineKey(registryID: registryID)
        let opener = DaemonLoopbackOpener(client: daemon.isLocal ? debugClient(registryID) : client(for: daemon))
        let port: UInt16
        do {
            port = try await proxy.listen(for: key, route: .init(machineName: name, opener: opener))
        } catch {
            logger.error("remote-localhost proxy for \(name, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            return nil
        }
        configuration.machineStore = BrowserMachineStore(machineKey: key, machineName: name, proxyPort: port)
        configuration.navigationGuard = .loopbackOnly
        return configuration
    }

    /// 16 hex digits of SHA-256 over the daemon `registry_id`.
    public static func machineKey(registryID: String) -> String {
        SHA256.hash(data: Data(registryID.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// The same short name as the machine badge of the machine's terminal
    /// tabs (Cloud title or SSH host), else the daemon's session name.
    public func machineName(of daemon: DaemonService) -> String {
        machines.machineBadge(daemon.machineID) ?? daemon.identity?.session ?? daemon.machineID
    }

    // MARK: Badge

    /// The machine chip of a browser tab showing `url`: shown only for a
    /// loopback page of a tab whose machine is not this Mac.
    public func badge(for tab: TabModel, url: URL?, engine: BrowserEngineKind) -> (text: String, help: String)? {
        guard let url, LoopbackHost(url: url)?.isLoopback == true else { return nil }
        switch route(for: tab, engine: engine) {
        case .thisMac:
            return nil
        case .machine(let name):
            return (name, RemoteLocalhostStrings.helpMachine(name))
        case .thisMacInstead(let name, let reason):
            let help = switch reason {
            case .updateMachine: RemoteLocalhostStrings.helpUpdate(name)
            case .turnedOff: RemoteLocalhostStrings.helpTurnedOff
            case .webKit: RemoteLocalhostStrings.helpWebKit(name)
            }
            return (RemoteLocalhostStrings.thisMac, help)
        }
    }

    /// The tab with durable id `id` on any machine.
    public func tab(id: String) -> TabModel? {
        for daemon in machines.daemons {
            if let tab = daemon.store.workspaces.lazy.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs).first(where: { $0.id == id }) {
                return tab
            }
        }
        return nil
    }

    // MARK: Transport

    private func client(for daemon: DaemonService) -> LoopbackForwardClient {
        let key = ObjectIdentifier(daemon)
        if let client = clients[key] { return client }
        let client = LoopbackForwardClient { [weak daemon] in
            guard let daemon else { throw DaemonError.notConnected }
            return try await daemon.endpoint()
        }
        clients[key] = client
        return client
    }

    /// The forwarding connection of `machine` (browser runtimes and their
    /// streams use it too, cx-2cob slice 2); nil for a machine with no daemon here.
    public func loopbackClient(machine: String) -> LoopbackForwardClient? {
        machines.daemon(machine: machine).map { client(for: $0) }
    }

    /// Opens a byte stream to `port` on the loopback of `machine` over its
    /// forwarding connection; nil for a machine with no daemon here.
    public func loopbackOpener(machine: String) -> (@Sendable (UInt16) async throws -> LoopbackStream)? {
        guard let client = loopbackClient(machine: machine) else { return nil }
        return { port in try await client.open(host: "127.0.0.1", port: port) }
    }

    /// Registers an authenticated `cmux-cloud` proxy behind the peer-checked app proxy.
    ///
    /// - Parameters:
    ///   - machineKey: The stable, non-secret key used for this machine's Chromium store.
    ///   - machineName: The machine name shown by the browser badge and error page.
    ///   - incarnation: The `cmux-cloud` process incarnation that owns this route.
    ///   - generation: The `cmux-cloud` link generation that owns this route.
    ///   - proxyPort: The loopback port returned by `cloud.browser.open`.
    ///   - proxyUsername: The HMAC user name returned by `cloud.browser.open`.
    ///   - proxyPassword: The random HMAC secret returned by `cloud.browser.open`.
    /// - Returns: A Chromium machine store that points only at the app's peer-checked proxy.
    public func cloudBrowserStore(
        machineKey: String,
        machineName: String,
        incarnation: UInt64,
        generation: UInt64,
        proxyPort: UInt16,
        proxyUsername: String,
        proxyPassword: String
    ) async throws -> BrowserMachineStore {
        let opener = CloudProxyLoopbackOpener(
            proxyPort: proxyPort,
            credential: ProxyCredential(username: proxyUsername, password: proxyPassword)
        )
        let port = try await proxy.listen(
            for: machineKey,
            incarnation: incarnation,
            generation: generation,
            route: .init(
                machineName: machineName,
                opener: opener,
                allowsDirectDestinations: false
            )
        )
        return BrowserMachineStore(machineKey: machineKey, machineName: machineName, proxyPort: port)
    }

    private var debugClients: [String: LoopbackForwardClient] = [:]
    /// The last store plan per tab id (`debug.remote-localhost`), bounded by
    /// the number of Chromium pages created this session.
    private var plans: [String: String] = [:]

    private func debugClient(_ socket: String) -> LoopbackForwardClient {
        if let client = debugClients[socket] { return client }
        let client = LoopbackForwardClient { DaemonEndpoint(socketPath: socket) }
        debugClients[socket] = client
        return client
    }

    /// Proxy port, counters and recent outcomes (`debug.remote-localhost`).
    public func report() -> CmuxNextSettings.JSONValue {
        typealias JSONValue = CmuxNextSettings.JSONValue
        let stats = proxy.stats
        let counters: [String: Int] = [
            "accepted": stats.accepted, "unauthorized": stats.unauthorized, "tunnels": stats.tunnels,
            "direct": stats.direct, "refused_local": stats.refusedLocal, "failures": stats.failures, "open": stats.open,
        ]
        return .object([
            "ports": .object(proxy.machinePorts.mapValues { .number(Double($0)) }),
            "enabled": .bool(setting.enabled),
            "machines": .number(Double(clients.count + debugClients.count)),
            "debug_socket": debugSocket.map(JSONValue.string) ?? .null,
            "proxy": .object(counters.mapValues { .number(Double($0)) }),
            "recent": .array(proxy.recentEvents.map(JSONValue.string)),
            "plans": .object(plans.mapValues(JSONValue.string)),
        ])
    }

    /// Closes the forwarding connection of a machine that left the registry:
    /// its streams and browser runtimes end with it.
    public func closeClient(of daemon: DaemonService) {
        guard let client = clients.removeValue(forKey: ObjectIdentifier(daemon)) else { return }
        // task-owner: one connection close; ends when the client has closed.
        Task { await client.close() }
    }

    public func shutdown() async {
        proxy.stop()
        for client in clients.values { await client.close() }
        for client in debugClients.values { await client.close() }
        clients.removeAll()
        debugClients.removeAll()
    }
}

import CmuxNextBrowser
import CmuxNextDaemon
import CmuxNextRemoteLocalhost
import CmuxNextSettings
import CryptoKit
import Foundation
import Observation
import os

/// Which localhost a browser tab sees (plans/cmux-next/remote-localhost.md).
enum RemoteLocalhostRoute: Equatable {
    /// The tab's machine is this Mac.
    case thisMac
    /// The tab's machine is `machine`, and its localhost is forwarded.
    case machine(String)
    /// The tab's machine is `machine`, but localhost is this Mac: the badge
    /// says so and names why.
    case thisMacInstead(String, RemoteLocalhostFallback)

    /// The remote machine's name, nil for this Mac.
    var machineName: String? {
        switch self {
        case .thisMac: nil
        case .machine(let name), .thisMacInstead(let name, _): name
        }
    }
}

/// Which store a Chromium page of a tab uses (remote-localhost.md section 3).
enum RemoteLocalhostStorePlan: Equatable {
    /// The browser profile's own store, with this navigation guard.
    case profile(BrowserNavigationGuard)
    /// The derived store (profile x machine) behind the proxy.
    case derived

    /// A remote machine's loopback URL gets the derived store; any other URL
    /// of a remote tab stays in the profile's store and may not navigate to
    /// loopback. Tabs of this Mac, and remote tabs whose localhost is this Mac
    /// on purpose (update, turned off, WebKit), are unrestricted.
    static func plan(route: RemoteLocalhostRoute, url: URL?) -> RemoteLocalhostStorePlan {
        guard case .machine = route else { return .profile(.none) }
        return url.map(LoopbackHost.isLoopback(url:)) == true ? .derived : .profile(.noLoopback)
    }
}

enum RemoteLocalhostFallback: Equatable {
    /// The machine's cmux-tui lacks `loopback-forward-v1`.
    case updateMachine
    /// `browser.remoteLocalhost` (or the workspace override) is off.
    case turnedOff
    /// WebKit tabs do not forward yet (stage 4).
    case webKit
}

/// Remote localhost for browser tabs: decides each tab's route and store,
/// owns the in-process proxy and one forwarding connection per machine.
/// Nothing starts until a tab of a remote machine needs it.
@MainActor
final class RemoteLocalhostService {
    private let machines: MachineRegistry
    private let proxy = RemoteLocalhostProxy()
    private var clients: [ObjectIdentifier: LoopbackForwardClient] = [:]
    private var starting: Task<UInt16?, Never>?
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "remote-localhost")
    /// cmux.json `browser.remoteLocalhost*`, live.
    var setting: RemoteLocalhostSetting = .fallback
    @ObservationIgnored private var observation: Task<Void, Never>?

    /// DEBUG builds: `CMUX_NEXT_REMOTE_LOCALHOST_DEBUG_SOCKET` names a second
    /// cmux-tui socket whose machine the tabs of this Mac use, so the
    /// Chromium path can be verified with a second local daemon. Nil in
    /// release builds.
    private let debugSocket: String?

    init(machines: MachineRegistry, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.machines = machines
        #if DEBUG
        debugSocket = environment["CMUX_NEXT_REMOTE_LOCALHOST_DEBUG_SOCKET"].flatMap { $0.isEmpty ? nil : $0 }
        #else
        debugSocket = nil
        #endif
    }

    private static let debugMachineName = "debug-remote"

    func follow(_ settings: SettingsController) {
        observation?.cancel()
        observation = Task { [weak self] in
            for await value in Observations({ settings.snapshot.remoteLocalhost }) {
                self?.setting = value
            }
        }
    }

    // MARK: Routing

    /// The route of `tab` for `engine`. A page cannot influence it: it
    /// depends only on which daemon holds the tab, the settings and the
    /// daemon's capabilities.
    func route(for tab: TabModel, engine: BrowserEngineKind) -> RemoteLocalhostRoute {
        let daemon = machines.daemon(forTab: tab)
        if daemon.isLocal, debugSocket != nil {
            return engine == .cef ? .machine(Self.debugMachineName) : .thisMacInstead(Self.debugMachineName, .webKit)
        }
        guard !daemon.isLocal else { return .thisMac }
        let name = machineName(of: daemon)
        let workspace = daemon.store.pane(containing: tab.surface).flatMap { daemon.store.workspace(containing: $0.handle) }
        guard setting.isEnabled(workspace: workspace?.id) else { return .thisMacInstead(name, .turnedOff) }
        guard daemon.supports(DaemonCapabilities.loopbackForward) else { return .thisMacInstead(name, .updateMachine) }
        guard engine == .cef else { return .thisMacInstead(name, .webKit) }
        return .machine(name)
    }

    /// `base` with the store and navigation guard for `tab` showing `url`:
    /// a loopback URL of a remote machine gets the derived store (its
    /// requests go through the proxy); any other URL of a remote tab keeps
    /// the profile's store and may not navigate to loopback, so this Mac's
    /// localhost is never reached silently. Nil when the proxy failed to
    /// start (the caller shows the failure instead of loading).
    func configuration(for tab: TabModel, url: URL?, base: BrowserTabConfiguration) async -> BrowserTabConfiguration? {
        var configuration = base
        let route = route(for: tab, engine: .cef)
        switch RemoteLocalhostStorePlan.plan(route: route, url: url) {
        case .profile(let guardMode):
            configuration.navigationGuard = guardMode
            return configuration
        case .derived:
            break
        }
        guard case .machine(let name) = route else { return configuration }
        let daemon = machines.daemon(forTab: tab)
        let registryID = daemon.isLocal ? debugSocket : daemon.store.registryID
        guard let port = await proxyPort(), let registryID else { return nil }
        let key = Self.machineKey(registryID: registryID)
        let opener = DaemonLoopbackOpener(client: daemon.isLocal ? debugClient(registryID) : client(for: daemon))
        let credential = proxy.credential(for: key, route: .init(machineName: name, opener: opener))
        configuration.machineStore = BrowserMachineStore(machineKey: key, machineName: name, proxyPort: port,
                                                         username: credential.username, password: credential.password)
        configuration.navigationGuard = .loopbackOnly
        return configuration
    }

    /// 16 hex digits of SHA-256 over the daemon `registry_id`.
    static func machineKey(registryID: String) -> String {
        SHA256.hash(data: Data(registryID.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    func machineName(of daemon: DaemonService) -> String {
        if let session = machines.session(daemon.machineID) {
            return session.machine.displayName ?? session.machine.slug ?? session.machineID
        }
        return daemon.identity?.session ?? daemon.machineID
    }

    // MARK: Badge

    /// The machine chip of a browser tab showing `url`: shown only for a
    /// loopback page of a tab whose machine is not this Mac.
    func badge(for tab: TabModel, url: URL?, engine: BrowserEngineKind) -> (text: String, help: String)? {
        guard let url, LoopbackHost.isLoopback(url: url) else { return nil }
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
    func tab(id: String) -> TabModel? {
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

    private var debugClients: [String: LoopbackForwardClient] = [:]

    private func debugClient(_ socket: String) -> LoopbackForwardClient {
        if let client = debugClients[socket] { return client }
        let client = LoopbackForwardClient { DaemonEndpoint(socketPath: socket) }
        debugClients[socket] = client
        return client
    }

    private func proxyPort() async -> UInt16? {
        if let port = proxy.port { return port }
        if let starting { return await starting.value }
        let proxy = proxy, logger = logger
        let task = Task<UInt16?, Never> {
            do {
                return try await proxy.start()
            } catch {
                logger.error("remote-localhost proxy failed to start: \(String(describing: error), privacy: .public)")
                return nil
            }
        }
        starting = task
        defer { starting = nil }
        return await task.value
    }

    /// Counters and open streams (`debug.remote-localhost`).
    func diagnostics() async -> [String: Any] {
        var streams = 0
        for client in clients.values { streams += await client.openStreamCount }
        let stats = proxy.stats
        return [
            "port": proxy.port.map(Int.init) as Any,
            "enabled": setting.enabled,
            "machines": clients.count,
            "open_streams": streams,
            "proxy": [
                "accepted": stats.accepted, "unauthorized": stats.unauthorized, "tunnels": stats.tunnels,
                "direct": stats.direct, "refused_local": stats.refusedLocal, "failures": stats.failures, "open": stats.open,
            ],
        ]
    }

    func shutdown() async {
        proxy.stop()
        for client in clients.values { await client.close() }
        for client in debugClients.values { await client.close() }
        clients.removeAll()
        debugClients.removeAll()
    }
}

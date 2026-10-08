import CmuxNextBrowser
import CmuxNextDaemon
import CmuxNextRemoteLocalhost
import CmuxNextSettings
import CryptoKit
import Foundation
import Observation
import os

/// Remote localhost for browser tabs: decides each tab's route and store,
/// owns the in-process proxy and one forwarding connection per machine.
/// Nothing starts until a tab of a remote machine needs it.
@MainActor
final class RemoteLocalhostService {
    private let machines: MachineRegistry
    private let proxy = RemoteLocalhostProxy()
    private var clients: [ObjectIdentifier: LoopbackForwardClient] = [:]
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
        guard daemon.supports(DaemonCapabilities.shared.loopbackForward) else { return .thisMacInstead(name, .updateMachine) }
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
    static func machineKey(registryID: String) -> String {
        SHA256.hash(data: Data(registryID.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// The same short name as the machine badge of the machine's terminal
    /// tabs (Cloud title or SSH host), else the daemon's session name.
    func machineName(of daemon: DaemonService) -> String {
        machines.machineBadge(daemon.machineID) ?? daemon.identity?.session ?? daemon.machineID
    }

    // MARK: Badge

    /// The machine chip of a browser tab showing `url`: shown only for a
    /// loopback page of a tab whose machine is not this Mac.
    func badge(for tab: TabModel, url: URL?, engine: BrowserEngineKind) -> (text: String, help: String)? {
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
    func report() -> CmuxNextSettings.JSONValue {
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

    func shutdown() async {
        proxy.stop()
        for client in clients.values { await client.close() }
        for client in debugClients.values { await client.close() }
        clients.removeAll()
        debugClients.removeAll()
    }
}

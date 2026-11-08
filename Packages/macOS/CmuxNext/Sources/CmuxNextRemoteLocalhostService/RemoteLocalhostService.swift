public import CmuxNextBrowser
import CmuxNextCompat
public import CmuxNextDaemon
public import CmuxNextDaemonService
public import CmuxNextRemoteLocalhost
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
    /// The app's WireGuard tunnel (`CloudTunnelHub.endpoint()`): Open Desktop's route to a Cloud
    /// machine, as cmux Classic reaches a machine's desktop. Nil until the app sets it.
    public var cloudTunnelSocket: HubLoopbackOpener.Hub?
    @ObservationIgnored private var observation: Task<Void, Never>?

    /// DEBUG builds: `CMUX_NEXT_REMOTE_LOCALHOST_DEBUG_SOCKET` names a second
    /// cmux-tui socket whose machine the tabs of this Mac use, so the
    /// Chromium path can be verified with a second local daemon. Nil in
    /// release builds.
    private let debugSocket: String?

    public init(machines: any RemoteLocalhostMachines, environment: [String: String] = ProcessInfo.processInfo.environment,
                defaults: UserDefaults = .standard) {
        self.machines = machines
        self.defaults = defaults
        #if DEBUG
        debugSocket = environment["CMUX_NEXT_REMOTE_LOCALHOST_DEBUG_SOCKET"].flatMap { $0.isEmpty ? nil : $0 }
        #else
        debugSocket = nil
        #endif
        for entry in defaults.stringArray(forKey: Self.boundDefaultsKey) ?? [] {
            let parts = entry.split(separator: "\t", maxSplits: 1).map(String.init)
            guard parts.count == 2, boundTabs.updateValue(parts[1], forKey: parts[0]) == nil else { continue }
            boundOrder.append(parts[0])
        }
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
    /// An Open Desktop page (`url` names its Cloud machine, ``cloudDesktopURL(machine:)``) in a
    /// tab of this Mac's daemon routes to that machine, never to this Mac. In a remote tree's tab
    /// the same address is that machine's own loopback: a remote tree never reaches another
    /// machine through this Mac's tunnel.
    public func route(for tab: TabModel, engine: BrowserEngineKind, url: URL? = nil) -> RemoteLocalhostRoute {
        if let machine = boundTabs[tab.id] { return boundRoute(machine, engine: engine) }
        if let machine = Self.desktopMachine(url: url, tabIsLocal: machines.daemon(forTab: tab).isLocal) {
            let name = machines.cloudMachineBadge(machine: machine) ?? machine
            return engine == .cef ? .machine(name) : .thisMacInstead(name, .webKit)
        }
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
        let route = route(for: tab, engine: .cef, url: url)
        let plan = storePlan(for: tab, url: url)
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
        case .blank:
            return nil
        }
        guard case .machine(let name) = route else { return configuration }
        // A tab bound to a chat's machine (``expectPage(_:machine:)``) reaches that machine, whichever holds it.
        let daemon: DaemonService
        if let bound = boundTabs[tab.id] {
            guard let found = machines.daemon(machine: bound) else { return nil }
            daemon = found
        } else {
            daemon = machines.daemon(forTab: tab)
        }
        let key: String, opener: any LoopbackTunnelOpening
        if let machine = Self.desktopMachine(url: url, tabIsLocal: daemon.isLocal) {
            // Open Desktop: over the app's WireGuard tunnel, in its own store, to that machine's
            // desktop host and noVNC port only. No tunnel (signed out, the machine gone or without
            // an address) is nil: a blank page, never this Mac.
            guard let socket = cloudTunnelSocket, let address = machines.cloudTunnelAddress(machine: machine),
                  let hub = HubLoopbackOpener(hub: socket, address: address) else { return nil }
            key = Self.machineKey(registryID: "cloud-tunnel:" + machine)
            opener = CloudDesktopOpener(base: hub, machine: machine)
        } else {
            guard let registryID = daemon.isLocal ? debugSocket : daemon.store.registryID else { return nil }
            key = Self.machineKey(registryID: registryID)
            opener = DaemonLoopbackOpener(client: daemon.isLocal ? debugClient(registryID) : client(for: daemon))
        }
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

    /// The store plan of `tab` showing `url` (``RemoteLocalhostStorePlan/plan(route:url:)``). A tab
    /// bound to a chat's machine never reaches this Mac's localhost: when that machine's localhost
    /// cannot be reached (it left, or remote localhost was turned off), a loopback page stays blank
    /// and any other page may not navigate to loopback.
    public func storePlan(for tab: TabModel, url: URL?) -> RemoteLocalhostStorePlan {
        let route = route(for: tab, engine: .cef, url: url)
        if boundTabs[tab.id] != nil, case .thisMacInstead = route {
            return url.flatMap(LoopbackHost.init(url:))?.isLoopback == true ? .blank : .profile(.noLoopback)
        }
        return RemoteLocalhostStorePlan.plan(route: route, url: url)
    }

    // MARK: Chat machine tabs

    /// Pages made for a chat's machine (``expectPage(_:machine:)``) that no tab holds yet.
    private var expectedPages: [ObjectIdentifier: (machine: String, until: ContinuousClock.Instant)] = [:]
    /// Tabs whose localhost is a chat's machine, by tab id, whatever machine's tree holds them:
    /// a Cloud chat's sign-in page (Claude's automatic page, AgentPaneSignInPage.swift), whose
    /// approve redirects to `http://localhost:<port>/callback` on the chat's machine. Kept in
    /// `UserDefaults` too (as ``ProxiedBrowserTabs`` keeps its tabs), so a restored tab is still
    /// bound after a relaunch: with its machine gone or remote localhost off, its loopback page
    /// stays blank, never this Mac's localhost. A live tab is never unbound: past
    /// ``boundLimit`` only the bindings of closed tabs are dropped.
    private var boundTabs: [String: String] = [:]
    private var boundOrder: [String] = []
    private let defaults: UserDefaults
    public static let boundDefaultsKey = "cmux.next.browser.chatMachineTabs"
    static let boundLimit = 256

    /// `page`, made in the profile's store with a `.noLoopback` guard, is for a tab whose localhost
    /// is the machine of daemon `machine` (a chat's): the tab that adopts it within a minute
    /// (``adoptPage(_:key:)``) routes its loopback pages there, through that machine's
    /// `loopback-forward-v1`, so the person's own store keeps every other page.
    public func expectPage(_ page: AnyObject, machine: String) {
        let now = ContinuousClock.now
        expectedPages = expectedPages.filter { $0.value.until > now }
        expectedPages[ObjectIdentifier(page)] = (machine, now + .seconds(60))
    }

    /// A page installed for tab `key`: the tab takes the machine a page made for it was expected
    /// for (``expectPage(_:machine:)``). Nothing for any other page.
    public func adoptPage(_ page: AnyObject, key: String) {
        guard !expectedPages.isEmpty, let expected = expectedPages.removeValue(forKey: ObjectIdentifier(page)),
              expected.until > .now else { return }
        bind(key, machine: expected.machine)
    }

    /// The machine tab `id` is bound to (``adoptPage(_:key:)``), if any.
    public func boundMachine(ofTab id: String) -> String? { boundTabs[id] }

    /// Tab `key` takes daemon `machine`'s localhost, kept across relaunches.
    func bind(_ key: String, machine: String) {
        if boundTabs.updateValue(machine, forKey: key) == nil { boundOrder.append(key) }
        if boundOrder.count > Self.boundLimit {
            // Only closed tabs' bindings go (a tab not on any machine now); a live tab keeps its own.
            let gone = Set(boundOrder.filter { tab(id: $0) == nil }.prefix(boundOrder.count - Self.boundLimit))
            boundOrder.removeAll { gone.contains($0) }
            for id in gone { boundTabs.removeValue(forKey: id) }
        }
        defaults.set(boundOrder.compactMap { id in boundTabs[id].map { id + "\t" + $0 } }, forKey: Self.boundDefaultsKey)
    }

    /// The route of a tab bound to daemon `machine`: that machine's, as for a tab of its own tree
    /// (the person's per-workspace choice aside); a machine no longer here is not reached.
    private func boundRoute(_ machine: String, engine: BrowserEngineKind) -> RemoteLocalhostRoute {
        guard let daemon = machines.daemon(machine: machine), !daemon.isLocal else { return .thisMacInstead(machine, .updateMachine) }
        return route(daemon: daemon, workspace: nil, engine: engine)
    }

    // MARK: Open Desktop

    /// The host suffix of an Open Desktop page: `<machine id>.cloud-desktop.localhost`, a name
    /// under `.localhost` (loopback by the remote-localhost rule) that carries its machine, so the
    /// route follows the page's own URL through relaunches, moves and hibernation.
    static let desktopHostSuffix = BrowserNavigationGuard.cloudDesktopHostSuffix

    /// Cloud machine `machine`'s desktop: its noVNC (6901 on the machine's loopback) at a host
    /// that names the machine; it connects at once, scales to the tab and reconnects by itself.
    /// Nil for an id that is not one DNS label.
    public static func cloudDesktopURL(machine: String) -> URL? {
        let label = machine.lowercased()
        guard isLabel(label) else { return nil }
        return URL(string: "http://\(label)\(desktopHostSuffix):6901/vnc.html?autoconnect=1&resize=scale&reconnect=1")
    }

    /// The Cloud machine an Open Desktop page of a tab names: only for a tab of this Mac's daemon.
    static func desktopMachine(url: URL?, tabIsLocal: Bool) -> String? {
        tabIsLocal ? desktopMachine(url: url) : nil
    }

    /// The Cloud machine an Open Desktop page names; nil for any other URL.
    public static func desktopMachine(url: URL?) -> String? {
        guard let host = url?.host(percentEncoded: false)?.lowercased(), host.hasSuffix(desktopHostSuffix) else { return nil }
        let label = String(host.dropLast(desktopHostSuffix.count))
        return isLabel(label) ? label : nil
    }

    private static func isLabel(_ text: String) -> Bool {
        !text.isEmpty && text.utf8.count <= 63 && text.first != "-" && text.last != "-"
            && text.utf8.allSatisfy { ($0 >= 0x61 && $0 <= 0x7A) || ($0 >= 0x30 && $0 <= 0x39) || $0 == 0x2D }
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
        switch route(for: tab, engine: engine, url: url) {
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
            // Tabs bound to a chat's machine (a Cloud chat's sign-in page): tab id to that machine's name.
            "bound": .object(boundTabs.mapValues { id in .string(machines.daemon(machine: id).map(machineName(of:)) ?? id) }),
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

/// Open Desktop's way into a Cloud machine: only that machine's desktop host
/// (`<machine>.cloud-desktop.localhost`) and its noVNC port. A page in the desktop store that
/// asks for another port (any other service on the machine's private address) or another
/// machine's desktop host (which would show this machine under that one's badge) is refused.
nonisolated struct CloudDesktopOpener: LoopbackTunnelOpening {
    static let port: UInt16 = 6901
    let base: any LoopbackTunnelOpening
    let host: String

    init(base: any LoopbackTunnelOpening, machine: String) {
        self.base = base
        host = machine.lowercased() + BrowserNavigationGuard.cloudDesktopHostSuffix
    }

    func openTunnel(host: String, port: UInt16) async throws(LoopbackTunnelFailure) -> any LoopbackTunnel {
        guard port == Self.port else { throw .portNotAllowed }
        guard host.lowercased() == self.host else { throw .other("Only this machine's desktop goes through the Cloud tunnel") }
        return try await base.openTunnel(host: host, port: port)
    }
}

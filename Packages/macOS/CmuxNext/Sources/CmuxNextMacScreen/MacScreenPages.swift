public import AppKit
import CmuxNextCompat
public import CmuxNextDevices
public import CmuxNextWakeups
import CmuxScreenKit
import Foundation

/// What a Mac Screen tab asks of the app that hosts its tabs.
public struct MacScreenTabEvents {
    /// Tab `key`'s title changed (the Mac was renamed, the tab shows another record).
    public var titleChanged: (String) -> Void = { _ in }
    /// The home page of tab `key` asks for `record` in a new tab beside it (a person's open).
    public var openInNewTab: (MacScreenRecord, String) -> Void = { _, _ in }
    /// Tab `key` asks to close.
    public var closeTab: (String) -> Void = { _ in }
    /// A person asked tab `key` to show `record` instead (Connect on the home
    /// page, Home on a screen): the host opens `record` as a new tab right
    /// after `key`, selects it, then closes `key`, so the tab's route names
    /// what it shows. False when it cannot (no pane lists `key`): the tab
    /// shows `record` itself.
    public var replaceTab: (MacScreenRecord, String) -> Bool = { _, _ in false }
    /// The store tab id of tab `key` (a tab the pane's daemon keeps and
    /// restores), nil for an app-only tab. For `debug.mac_screen`.
    public var storeTabID: (String) -> String? = { _ in nil }
    /// Titles that come from routes changed (device names were read or
    /// renamed): strips draw their unopened Mac Screen tabs again.
    public var routeTitlesChanged: () -> Void = {}

    public init() {}
}

/// Mac Screen tabs, their own page tab kind (the app's `mac-screen` page):
/// the user's devices through the device hub, this Mac as a hub host
/// (`MacScreenHubHost`, its permissions in `MacScreenShareHost`), and each
/// tab (`MacScreenTab`) by its page tab key. A device tab asks the hub only
/// when a person opened it with a scope in this process; tabs that
/// automation opened, or that were restored, wait at the Connect card.
/// Pairing links are gone: a tab restored on an old link record shows that
/// they are no longer supported.
@MainActor
public final class MacScreenPages {
    public let store: MacScreenStore
    public let host: MacScreenShareHost
    /// This Mac as a device hub host (Allow Mac Screen on this Mac, approved sessions).
    public let hubHost: MacScreenHubHost
    /// The host's approval prompt for device hub requests.
    public let approval = MacScreenApprovalPrompt()
    /// The device hub while this app is signed in to one (the app sets it on
    /// sign-in and clears it on sign-out): the user's devices, and the session
    /// pushes Mac Screen follows.
    public var hub: DeviceHub? {
        didSet {
            guard hub !== oldValue else { return }
            hubBox.hub = hub
            hubChanged(from: oldValue)
        }
    }
    /// Whether this build has a usable device hub address: always, unless a
    /// DEV build's `deviceHub.url` override is not valid. The home page says
    /// "sign in" when it does and asks to fix the address when it does not.
    public var hubConfigured: Bool {
        get { hubBox.configured }
        set { hubBox.configured = newValue }
    }
    /// The hub as views observe it.
    let hubBox = MacScreenHubBox()
    /// Scopes a person chose for a device on the home page, until its tab asks the hub.
    var pendingScopes: [String: SessionScope] = [:]
    private var namesWatch: Task<Void, Never>?
    /// Send System Shortcuts to the Remote Mac: the app's one system shortcut tap.
    public let systemShortcuts: MacScreenSystemShortcuts
    public var events = MacScreenTabEvents()
    /// The app's shortcut matcher: true keeps a key down in cmux.
    public var isLocalShortcut: (NSEvent) -> Bool = { _ in false }
    /// Settings > Development > Relay Only (`macScreen.debug.relayOnly`):
    /// sessions use the TURN relay only. Only DEV builds apply it; the app
    /// feeds it from the setting there.
    public var relayOnly = false {
        didSet {
            #if DEBUG
            guard relayOnly != oldValue else { return }
            for tab in tabs.values { tab.pane?.setRelayOnly(relayOnly) }
            #endif
        }
    }
    /// Tab key -> the record a person opened in it.
    private var confirmed: [String: MacScreenRecord] = [:]
    /// Tab key -> the record it shows, set before its view is made.
    private var records: [String: MacScreenRecord] = [:]
    /// Open tabs (made views), by key.
    private(set) var tabs: [String: MacScreenTab] = [:]
    private var termination: (any NSObjectProtocol)?

    /// - Parameters:
    ///   - store: the saved Mac Screen records.
    ///   - work: the app's blocking-work lanes (the permission checks run on its system lane).
    public init(store: MacScreenStore, work: BackgroundWork) {
        self.store = store
        host = MacScreenShareHost(work: work)
        hubHost = MacScreenHubHost(share: host)
        systemShortcuts = MacScreenSystemShortcuts(host: host)
        systemShortcuts.panes = { [weak self] in self?.tabs.values.compactMap(\.pane) ?? [] }
        // Quitting ends every session now, so the other Mac stops showing a viewer at once.
        termination = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { // main-proof: observer on queue: .main
                for tab in self?.tabs.values.map({ $0 }) ?? [] { tab.pane?.close() }
                self?.hubHost.stopSession(immediately: true)
            }
        }
        hubHost.hub = { [weak self] in self?.hub }
        approval.hub = { [weak self] in self?.hub }
    }

    // MARK: Device hub

    private func hubChanged(from old: DeviceHub?) {
        if old?.onSessionPush != nil { old?.onSessionPush = nil }
        // Signed out (or another account): every session ends here.
        if old != nil {
            hubHost.closeAll()
            for tab in tabs.values { tab.pane?.model.hub?.hubGone() }
        }
        hub?.onSessionPush = { [weak self] push in self?.handle(push) }
        approval.follow(hub)
        watchDeviceNames()
    }

    /// One `session.*` push: the viewer tab or the host it is for.
    func handle(_ push: DeviceHubPush) {
        switch push {
        case .sessionRequest:
            break // The approval prompt follows the hub's pending requests.
        case let .sessionTicket(ticket):
            switch ticket.role {
            case .host: hubHost.serve(ticket)
            case .viewer:
                // The tab whose session (or, before the request's answer, whose host) it names.
                let viewers = hubViewers
                let target = viewers.first(where: { $0.phase.sessionID == ticket.sessionId }) ?? viewers.first(where: { $0.accepts(ticket) })
                target?.accept(ticket)
            }
        case let .sessionDenied(id):
            for viewer in hubViewers where viewer.phase.sessionID == id { viewer.denied() }
        case let .sessionRevoked(id, reason):
            hubHost.sessionOver(id)
            for viewer in hubViewers where viewer.phase.sessionID == id { viewer.revoked(reason: reason) }
        case let .sessionEnded(id, reason):
            hubHost.sessionOver(id)
            for viewer in hubViewers where viewer.phase.sessionID == id { viewer.ended(reason: reason) }
        case .devicesChanged, .permissionsChanged, .relaysChanged, .pong, .unknown:
            break
        }
    }

    /// The device hub tabs' viewers, in key order.
    private var hubViewers: [MacScreenHubViewer] {
        tabs.values.sorted { $0.key < $1.key }.compactMap { $0.pane?.model.hub }
    }

    /// Device tabs take their device's name from the hub (renames show live).
    private func watchDeviceNames() {
        namesWatch?.cancel()
        guard let hub else { return }
        namesWatch = Task { [weak self] in
            for await names in ObservationStream({ hub.devices.map { [$0.id, $0.name, $0.online ? "1" : "0"] } }) {
                guard let self else { return }
                if store.rememberDeviceNames(Dictionary(names.map { ($0[0], $0[1]) }, uniquingKeysWith: { _, last in last })) {
                    refreshDeviceTitles()
                }
                // Only while this Mac's own link is up: then the hub's word on a host is current.
                if hub.connection == .connected {
                    for viewer in hubViewers {
                        if let entry = names.first(where: { $0[0] == viewer.deviceID }) { viewer.hostOnlineChanged(entry[2] == "1") }
                    }
                }
                for tab in tabs.values {
                    guard let id = tab.record.deviceID, let name = names.first(where: { $0[0] == id })?[1],
                          !name.isEmpty, tab.pane?.model.name != name else { continue }
                    tab.rename(name)
                    events.titleChanged(tab.key)
                }
            }
        }
    }

    /// The name of device `id`: the hub's, else the last one seen, else "Mac".
    func deviceName(_ id: String) -> String {
        hub?.devices.first { $0.id == id }?.name ?? store.deviceNames[id] ?? L.t("macScreen.hub.unknownDevice", "Mac")
    }

    /// Device tabs whose view is not made yet (restored, not selected) take their device's name.
    private func refreshDeviceTitles() {
        for (key, record) in records where record.deviceID != nil && tabs[key] == nil { events.titleChanged(key) }
        events.routeTitlesChanged()
    }

    /// The title of a tab known only by its route (a restored tab not yet
    /// shown): the device's name, else "Screen Sharing"; nil for no route.
    public func title(forRoute route: String?) -> String? {
        guard let route, let record = Self.record(route: route) else { return route == nil ? nil : Self.homeTitle }
        return record.deviceID.map(deviceName) ?? Self.homeTitle
    }

    /// The answer to a pasted or typed pairing link (`cmux-vnc://pair?…`) in any
    /// input surface: no longer supported. The App decides what is one
    /// (`BrowserURLResolver.containsPairingLink`); the text is never loaded,
    /// searched or sent to an agent.
    nonisolated public static var pairingLinkRefusal: String {
        L.t("macScreen.pairingLinkRefused", "Pairing links are no longer supported. Use Settings › Devices.")
    }

    /// The hub's sessions end here now with `reason` (this Mac was removed:
    /// `device_removed:viewer`), before the hub goes away and would say "signed out".
    public func endHubSessions(reason: String) {
        hubHost.closeAll()
        for viewer in hubViewers { viewer.hubGone(reason: reason) }
    }

    /// The home page opens device `id` asking for `scope` (a person's click).
    func openDeviceFromHome(_ id: String, scope: SessionScope?, in key: String) {
        if let scope { pendingScopes[id] = scope }
        replace(key, with: MacScreenRecord(deviceID: id))
    }

    /// The home page opens device `id` in a new tab beside it.
    func openDeviceInNewTab(_ id: String, scope: SessionScope?, from key: String) {
        if let scope { pendingScopes[id] = scope }
        events.openInNewTab(MacScreenRecord(deviceID: id), key)
    }

    /// At launch: the shortcut tap, the permissions, and the saved device names
    /// (the first launch of this build also removes old link pairings).
    public func activate() {
        systemShortcuts.start()
        Task { [weak self] in
            await self?.store.load()
            self?.host.activate()
            // The saved device names are in: restored device tabs take them.
            self?.refreshDeviceTitles()
        }
    }

    // MARK: Page tabs

    /// Tab `key` will show `record` (set up before its view is made). `byPerson`:
    /// a person opened it here, so it connects without asking.
    public func prepare(_ key: String, record: MacScreenRecord, byPerson: Bool) {
        records[key] = record
        if byPerson { confirmed[key] = record } else { confirmed[key] = nil }
    }

    /// What tab `key` shows, kept as its page tab route: "home",
    /// "device:<device id>", or an old link record's "mac:<id>" (restored, it
    /// shows that pairing links are no longer supported). Never a secret.
    public func route(for key: String) -> String? {
        Self.route(of: tabs[key]?.record ?? records[key] ?? MacScreenRecord(macID: nil))
    }

    /// The route of `record`.
    static func route(of record: MacScreenRecord) -> String {
        if let device = record.deviceID { return "device:" + device }
        return record.macID.map { "mac:" + $0.uuidString } ?? "home"
    }

    /// The record a route names; nil for anything else.
    public static func record(route: String) -> MacScreenRecord? {
        if route == "home" { return MacScreenRecord(macID: nil) }
        if route.hasPrefix("device:") {
            let id = String(route.dropFirst(7))
            guard MacScreenRecord.normalizedDeviceID(id) != nil else { return nil }
            return MacScreenRecord(deviceID: id)
        }
        guard route.hasPrefix("mac:"), let id = UUID(uuidString: String(route.dropFirst(4))) else { return nil }
        return MacScreenRecord(macID: id)
    }

    /// A tab came back on `route` (relaunch, Reopen Closed): it shows that
    /// record and waits for Connect. An unknown route shows the home page.
    public func restore(_ route: String, for key: String) {
        guard records[key] == nil else { return }
        let record = Self.record(route: route) ?? MacScreenRecord(macID: nil)
        prepare(key, record: record, byPerson: false)
        // The strip may have asked for the title before the route came back: a device tab is retitled once its pane lists it.
        if record.deviceID != nil {
            Task { @MainActor [weak self] in self?.events.titleChanged(key) }
        }
    }

    /// The home page's title, "Screen Sharing".
    public static var homeTitle: String { L.t("macScreen.tab.homeTitle", "Screen Sharing") }

    /// The title of tab `key`: the device's name, or "Screen Sharing".
    public func title(for key: String) -> String {
        if let tab = tabs[key] { return tab.title }
        return records[key]?.deviceID.map(deviceName) ?? Self.homeTitle
    }

    /// The view of tab `key` (once per tab).
    public func makeView(for key: String) -> MacScreenTabView {
        if let tab = tabs[key] { return tab.view }
        let record = records[key] ?? MacScreenRecord(macID: nil)
        let tab = MacScreenTab(key: key, record: record)
        tabs[key] = tab
        show(record, in: tab)
        return tab.view
    }

    /// Tab `key` closed: its session ends now.
    public func tabClosed(_ key: String) {
        tabs.removeValue(forKey: key)?.clear()
        records[key] = nil
        confirmed[key] = nil
        systemShortcuts.update()
    }

    /// The tab `key` (debug and tests).
    public func tab(_ key: String) -> MacScreenTab? { tabs[key] }

    /// A person asked tab `key` to show `record` (the home page's Connect, a screen's Home): a new tab in its place
    /// (`MacScreenTabEvents.replaceTab`), else this tab shows it.
    func replace(_ key: String, with record: MacScreenRecord) {
        if events.replaceTab(record, key) { return }
        show(record, in: key, byPerson: true)
    }

    /// Shows `record` in tab `key` in place of what it shows, when no host can
    /// open a tab in its place. `byPerson`: a person asked for it.
    public func show(_ record: MacScreenRecord, in key: String, byPerson: Bool) {
        guard let tab = tabs[key] else { return }
        prepare(key, record: record, byPerson: byPerson || confirmed[key] == record)
        show(record, in: tab)
        events.titleChanged(key)
    }

    private func show(_ record: MacScreenRecord, in tab: MacScreenTab) {
        tab.record = record
        let key = tab.key
        if let device = record.deviceID {
            tab.install(makeHubPane(deviceID: device, record: record, key: key))
            events.titleChanged(key)
            return
        }
        guard record.macID == nil else {
            // An old link record (link pairing is gone): it says so, with Close Tab.
            let pane = MacScreenPane(unsupportedLink: ())
            pane.handlers.closeTab = { [weak self] in self?.events.closeTab(key) }
            pane.handlers.openHome = { [weak self] in self?.replace(key, with: MacScreenRecord(macID: nil)) }
            tab.install(pane)
            return
        }
        tab.showHome(makeHome(key: key))
        tab.loading = Task { [weak self] in await self?.store.load() }
    }

    private func makeHome(key: String) -> NSView {
        var actions = MacScreenHomeActions()
        actions.openDevice = { [weak self] id, scope in self?.openDeviceFromHome(id, scope: scope, in: key) }
        actions.openDeviceInNewTab = { [weak self] id, scope in self?.openDeviceInNewTab(id, scope: scope, from: key) }
        // In the tab's theme scope: Settings > Appearance changes show at once. The page fills the tab.
        return MacScreenHomeView(host: host, actions: actions, systemShortcuts: systemShortcuts, devices: MacScreenHomeDevices(pages: self))
    }

    /// A device hub device's screen. A tab a person opened with a scope asks
    /// the hub when shown; any other waits at the Connect card.
    private func makeHubPane(deviceID: String, record: MacScreenRecord, key: String) -> MacScreenPane {
        let viewer = MacScreenHubViewer(deviceID: deviceID) { [weak self] in self?.hub }
        let pane = MacScreenPane(hubDevice: viewer, name: deviceName(deviceID), preferences: ScreenPreferences())
        if confirmed[key] == record, let scope = pendingScopes.removeValue(forKey: deviceID) { viewer.resumeScope = scope }
        #if DEBUG
        if relayOnly { pane.setRelayOnly(true) }
        #endif
        pane.handlers.closeTab = { [weak self] in self?.events.closeTab(key) }
        pane.handlers.openHome = { [weak self] in self?.replace(key, with: MacScreenRecord(macID: nil)) }
        pane.handlers.isLocalShortcut = { [weak self] event in self?.isLocalShortcut(event) ?? false }
        pane.handlers.keyboardChanged = { [weak self] in self?.systemShortcuts.update() }
        pane.model.systemShortcuts = systemShortcuts
        return pane
    }
}

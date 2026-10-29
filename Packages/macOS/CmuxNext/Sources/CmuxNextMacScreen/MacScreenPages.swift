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
    public let approval: MacScreenApprovalPrompt
    /// The app's main-thread scheduler: the tabs' views apply model changes on its frames, and the
    /// hub's answers land as its tasks.
    let mainWork: MainWorkScheduler
    /// The app's one deadline placer (the tabs' hidden grace, the hub requests' expiries).
    private let deadlines: MainDeadlineScheduler
    /// The app's one observer per app notice.
    private let appEvents: AppEvents
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
    var namesWatch: ServiceObservation<[DeviceLabel]>?
    /// The settings Mac Screen follows (``follow(_:refuse:)``).
    var settingsFollows: [ServiceObservation<Bool>] = []
    /// Send System Shortcuts to the Remote Mac: the app's one system shortcut tap.
    public let systemShortcuts: MacScreenSystemShortcuts
    public var events = MacScreenTabEvents()
    /// The app's shortcut matcher: true keeps a key down in cmux.
    public var isLocalShortcut: (NSEvent) -> Bool = { _ in false }
    /// The windows' frame-aligned pointer input for device screens (feature `pointerFrameRemoteInput`,
    /// ``RemoteInputSurface/pointerFrames``), read when a screen is made; nil sends each event at once.
    public var pointerFrames: @MainActor () -> FrameInputCoalescers? = { nil }
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
    /// Tab key -> the device and scope a discarded tab streamed, which its next view asks for
    /// again. Never another tab's: ``pendingScopes`` is what a person chose on the home page.
    private(set) var resumeScopes: [String: (deviceID: String, scope: SessionScope)] = [:]
    /// Open tabs (made views), by key.
    private(set) var tabs: [String: MacScreenTab] = [:]
    private var termination: EventSubscription?

    /// - Parameters:
    ///   - store: The saved device names.
    ///   - deadlines: The app's one deadline placer; its scheduler is the app's one main-thread
    ///     scheduler (``FrameObservation`` deliveries of the tabs' views and the approval prompt).
    ///   - appEvents: The app's one observer per app notice (quit, activation, key windows).
    ///   - work: The app's blocking-work lanes (the permission checks run on its system lane).
    public init(store: MacScreenStore, deadlines: MainDeadlineScheduler, appEvents: AppEvents, work: BackgroundWork) {
        self.store = store
        self.deadlines = deadlines
        self.appEvents = appEvents
        mainWork = deadlines.work
        approval = MacScreenApprovalPrompt(deadlines: deadlines)
        host = MacScreenShareHost(work: work)
        hubHost = MacScreenHubHost(share: host, mainWork: deadlines.work)
        systemShortcuts = MacScreenSystemShortcuts(host: host, appEvents: appEvents)
        systemShortcuts.panes = { [weak self] in self?.tabs.values.compactMap(\.pane) ?? [] }
        // Quitting ends every session now, so the other Mac stops showing a viewer at once (in the notice's turn).
        termination = appEvents.subscribe(NSApplication.willTerminateNotification, owner: "MacScreenPages.terminate") { [weak self] in
            for tab in self?.tabs.values.map({ $0 }) ?? [] { tab.pane?.close() }
            self?.hubHost.stopSession(immediately: true)
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
    var hubViewers: [MacScreenHubViewer] {
        tabs.values.sorted { $0.key < $1.key }.compactMap { $0.pane?.model.hub }
    }

    /// Device tabs whose view is not made yet (restored, not selected) take their device's name.
    func refreshDeviceTitles() {
        for (key, record) in records where record.deviceID != nil && tabs[key] == nil { events.titleChanged(key) }
        events.routeTitlesChanged()
    }

    /// The title of a tab known only by its route (a restored tab not yet
    /// shown): the device's name, else "Mac Screen"; nil for no route.
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
        let store = store, work = mainWork
        // task-owner: one launch read (the store reads its file off main), then one visible task: restored
        // device tabs take the saved names.
        Task { @concurrent [weak self] in
            await store.load()
            await work.apply(.visible, owner: "MacScreenPages.activate") { [weak self] () -> Void in
                guard let self else { return }
                host.activate(events: appEvents)
                refreshDeviceTitles()
            }
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
            mainWork.post(.visible, owner: "MacScreenPages.restoredTitle") { [weak self] in self?.events.titleChanged(key) }
        }
    }

    /// The home page's title, "Mac Screen".
    public static var homeTitle: String { L.t("macScreen.tab.homeTitle", "Mac Screen") }

    /// The title of tab `key`: the device's name, or "Mac Screen".
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
        resumeScopes[key] = nil
        systemShortcuts.update()
    }

    /// Tab `key`'s view was released and the tab stays (`memoryDiscardInternalPages`): its session
    /// ends now, as at ``tabClosed(_:)``, and its record stays for the view its next show makes. A
    /// tab that streamed, or whose stream ended for being hidden, asks again for the same scope
    /// when shown, as a hidden pane does (``MacScreenPane/resume()``).
    public func viewDiscarded(_ key: String) {
        guard let tab = tabs.removeValue(forKey: key) else { return }
        records[key] = tab.record
        if let device = tab.record.deviceID, let hub = tab.pane?.model.hub,
           let scope = hub.phase.streamingScope ?? hub.resumeScope {
            resumeScopes[key] = (device, scope)
        }
        tab.clear()
        systemShortcuts.update()
    }

    /// Whether tab `key` asked a Mac for its screen and waits on the answer (the other Mac's
    /// approval): ending the tab's view would withdraw the request.
    public func isRequesting(_ key: String) -> Bool {
        tabs[key]?.pane?.model.hub?.phase.isPending == true
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
            tab.install(makeHubPane(deviceID: device, record: record, tab: tab))
            events.titleChanged(key)
            return
        }
        guard record.macID == nil else {
            // An old link record (link pairing is gone): it says so, with Close Tab.
            let pane = MacScreenPane(unsupportedLinkIn: tab.node, on: mainWork)
            pane.handlers.closeTab = { [weak self] in self?.events.closeTab(key) }
            pane.handlers.openHome = { [weak self] in self?.replace(key, with: MacScreenRecord(macID: nil)) }
            tab.install(pane)
            return
        }
        tab.showHome(makeHome(key: key, node: tab.node))
        let store = store
        // task-owner: tab.loading: the store's one file read (off main); the tab's clear cancels the wait
        tab.loading = Task { @concurrent in await store.load() }
    }

    private func makeHome(key: String, node: VisibilityNode) -> NSView {
        var actions = MacScreenHomeActions()
        actions.openDevice = { [weak self] id, scope in self?.openDeviceFromHome(id, scope: scope, in: key) }
        actions.openDeviceInNewTab = { [weak self] id, scope in self?.openDeviceInNewTab(id, scope: scope, from: key) }
        // In the tab's theme scope: Settings > Appearance changes show at once. The page fills the tab.
        return MacScreenHomeView(host: host, actions: actions, node: node, on: mainWork, systemShortcuts: systemShortcuts,
                                 devices: MacScreenHomeDevices(pages: self))
    }

    /// A device hub device's screen. A tab a person opened with a scope asks
    /// the hub when shown; any other waits at the Connect card.
    private func makeHubPane(deviceID: String, record: MacScreenRecord, tab: MacScreenTab) -> MacScreenPane {
        let key = tab.key
        let viewer = MacScreenHubViewer(deviceID: deviceID, deadlines: deadlines) { [weak self] in self?.hub }
        let pane = MacScreenPane(hubDevice: viewer, name: deviceName(deviceID), preferences: ScreenPreferences(), node: tab.node, on: mainWork)
        if let resume = resumeScopes.removeValue(forKey: key), resume.deviceID == deviceID {
            viewer.resumeScope = resume.scope
        } else if confirmed[key] == record, let scope = pendingScopes.removeValue(forKey: deviceID) {
            viewer.resumeScope = scope
        }
        #if DEBUG
        if relayOnly { pane.setRelayOnly(true) }
        #endif
        pane.handlers.closeTab = { [weak self] in self?.events.closeTab(key) }
        pane.handlers.openHome = { [weak self] in self?.replace(key, with: MacScreenRecord(macID: nil)) }
        pane.handlers.isLocalShortcut = { [weak self] event in self?.isLocalShortcut(event) ?? false }
        pane.handlers.keyboardChanged = { [weak self] in self?.systemShortcuts.update() }
        pane.model.systemShortcuts = systemShortcuts
        pane.view.input.pointerFrames = pointerFrames()
        return pane
    }
}

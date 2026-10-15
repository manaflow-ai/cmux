public import AppKit
import CmuxScreenKit
import Foundation
import SwiftUI

/// What a Mac Screen tab asks of the app that hosts its tabs.
public struct MacScreenTabEvents {
    /// Tab `key`'s title changed (the Mac was renamed, the tab shows another record).
    public var titleChanged: (String) -> Void = { _ in }
    /// The home page of tab `key` asks for `record` in a new tab beside it (a person's open).
    public var openInNewTab: (MacScreenRecord, String) -> Void = { _, _ in }
    /// Tab `key` asks to close.
    public var closeTab: (String) -> Void = { _ in }

    public init() {}
}

/// Mac Screen tabs, their own page tab kind (the app's `mac-screen` page):
/// the saved Macs and Share This Mac (`MacScreenStore`, `MacScreenShareHost`),
/// and each tab (`MacScreenTab`) by its page tab key. A tab connects only
/// when a person opened it in this process (a click, the address bar, the
/// palette); tabs that automation opened, or that were restored, wait for
/// Connect.
@MainActor
public final class MacScreenPages {
    public let store: MacScreenStore
    public let host: MacScreenShareHost
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

    public init(store: MacScreenStore) {
        self.store = store
        host = MacScreenShareHost(store: store)
        systemShortcuts = MacScreenSystemShortcuts(host: host)
        systemShortcuts.panes = { [weak self] in self?.tabs.values.compactMap(\.pane) ?? [] }
        store.onRenamed = { [weak self] id, name in
            guard let self else { return }
            for tab in tabs.values where tab.record.macID == id {
                tab.rename(name)
                events.titleChanged(tab.key)
            }
        }
        store.onForgotten = { [weak self] id in
            for tab in self?.tabs.values.map({ $0 }) ?? [] where tab.record.macID == id { tab.pane?.forgotten() }
        }
        // Quitting ends every session now, so the other Mac stops showing a viewer at once.
        termination = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { // main-proof: observer on queue: .main
                for tab in self?.tabs.values.map({ $0 }) ?? [] { tab.pane?.close() }
            }
        }
    }

    /// At launch: Share This Mac resumes when the person left it on.
    public func activate() {
        systemShortcuts.start()
        Task { [weak self] in
            await self?.store.load()
            self?.host.activate()
        }
    }

    /// Saves the Mac a `cmux-vnc://pair` link names.
    public func pair(link: URL) -> MacScreenRecord? {
        guard case let .success(mac) = store.add(link: link.absoluteString) else { return nil }
        return MacScreenRecord(macID: mac.id)
    }

    // MARK: Page tabs

    /// Tab `key` will show `record` (set up before its view is made). `byPerson`:
    /// a person opened it here, so it connects without asking.
    public func prepare(_ key: String, record: MacScreenRecord, byPerson: Bool) {
        records[key] = record
        if byPerson { confirmed[key] = record } else { confirmed[key] = nil }
    }

    /// What tab `key` shows, kept as its page tab route: "home" or
    /// "mac:<saved Mac id>". Never the pairing secret (it stays in the Keychain).
    public func route(for key: String) -> String? {
        let record = tabs[key]?.record ?? records[key] ?? MacScreenRecord(macID: nil)
        return record.macID.map { "mac:" + $0.uuidString } ?? "home"
    }

    /// The record a route names; nil for anything else.
    public static func record(route: String) -> MacScreenRecord? {
        if route == "home" { return MacScreenRecord(macID: nil) }
        guard route.hasPrefix("mac:"), let id = UUID(uuidString: String(route.dropFirst(4))) else { return nil }
        return MacScreenRecord(macID: id)
    }

    /// A tab came back on `route` (relaunch, Reopen Closed): it shows that
    /// record and waits for Connect. An unknown route shows the home page.
    public func restore(_ route: String, for key: String) {
        guard records[key] == nil else { return }
        prepare(key, record: Self.record(route: route) ?? MacScreenRecord(macID: nil), byPerson: false)
    }

    /// The home page's title, "Mac Screen".
    public static var homeTitle: String { L.t("macScreen.tab.homeTitle", "Mac Screen") }

    /// The title of tab `key`: the Mac's name, or "Mac Screen" for the home page.
    public func title(for key: String) -> String {
        if let tab = tabs[key] { return tab.title }
        return records[key]?.macID.flatMap { store.mac($0)?.name } ?? Self.homeTitle
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

    /// Shows `record` in tab `key` in place of what it shows (Connect on the
    /// home page, Home on a screen). `byPerson`: a person asked for it.
    public func show(_ record: MacScreenRecord, in key: String, byPerson: Bool) {
        guard let tab = tabs[key] else { return }
        prepare(key, record: record, byPerson: byPerson || confirmed[key] == record)
        show(record, in: tab)
        events.titleChanged(key)
    }

    private func show(_ record: MacScreenRecord, in tab: MacScreenTab) {
        tab.record = record
        let key = tab.key
        guard let macID = record.macID else {
            tab.showHome(makeHome(key: key))
            tab.loading = Task { [weak self] in await self?.store.load() }
            return
        }
        tab.showLoading()
        tab.loading = Task { [weak self, weak tab] in
            guard let self else { return }
            await store.load()
            guard let tab, !Task.isCancelled, tabs[key] === tab, tab.record == record else { return }
            tab.install(makePane(macID: macID, record: record, key: key))
            events.titleChanged(key)
        }
    }

    private func makeHome(key: String) -> NSView {
        var actions = MacScreenHomeActions()
        actions.open = { [weak self] mac in self?.show(MacScreenRecord(macID: mac), in: key, byPerson: true) }
        actions.openInNewTab = { [weak self] mac in self?.events.openInNewTab(MacScreenRecord(macID: mac), key) }
        // In the tab's theme scope: Settings > Appearance changes show at once.
        let home = MacScreenHostingView(MacScreenHomeView(store: store, host: host, actions: actions, systemShortcuts: systemShortcuts))
        // The page fills the tab; its content never sizes the tab's layout.
        home.sizingOptions = []
        return home
    }

    private func makePane(macID: UUID, record: MacScreenRecord, key: String) -> MacScreenPane {
        let pane: MacScreenPane
        if let mac = store.mac(macID), let pairing = store.pairing(for: macID) {
            pane = MacScreenPane(name: mac.name, pairing: pairing, preferences: mac.preferences, confirmed: confirmed[key] == record)
            pane.session?.hostID = macID
            #if DEBUG
            if relayOnly { pane.setRelayOnly(true) }
            #endif
            pane.handlers.confirm = { [weak self] in self?.confirmed[key] = record }
            pane.handlers.connected = { [weak self] preferences in self?.store.connected(macID, preferences: preferences) }
            pane.handlers.preferencesChanged = { [weak self] preferences in self?.store.update(macID, preferences: preferences) }
        } else {
            pane = MacScreenPane(missingMac: ())
        }
        pane.handlers.closeTab = { [weak self] in self?.events.closeTab(key) }
        pane.handlers.openHome = { [weak self] in self?.show(MacScreenRecord(macID: nil), in: key, byPerson: true) }
        pane.handlers.isLocalShortcut = { [weak self] event in self?.isLocalShortcut(event) ?? false }
        pane.handlers.keyboardChanged = { [weak self] in self?.systemShortcuts.update() }
        pane.model.systemShortcuts = systemShortcuts
        return pane
    }
}

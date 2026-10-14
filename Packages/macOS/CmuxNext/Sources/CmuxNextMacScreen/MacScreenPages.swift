public import AppKit
public import CmuxNextBrowser
import CmuxScreenKit
import Foundation
import SwiftUI

/// Mac Screen tabs (`cmux://mac-screen`) for the app: the saved Macs and
/// Share This Mac (`MacScreenStore`, `MacScreenShareHost`), and each tab's
/// page. A tab connects only when a person opened it in this process (a
/// click, the address bar, the palette); tabs that automation opened, or
/// that were restored, wait for Connect.
@MainActor
public final class MacScreenPages {
    public let store: MacScreenStore
    public let host: MacScreenShareHost
    /// The app's shortcut matcher: true keeps a key down in cmux.
    public var isLocalShortcut: (NSEvent) -> Bool = { _ in false }
    /// Settings > Development > Relay Only (`macScreen.debug.relayOnly`):
    /// sessions use the TURN relay only. Only DEV builds apply it; the app
    /// feeds it from the setting there.
    public var relayOnly = false {
        didSet {
            #if DEBUG
            guard relayOnly != oldValue else { return }
            for tab in tabs.allObjects { tab.pane?.setRelayOnly(relayOnly) }
            #endif
        }
    }
    /// Tab key -> the record URL a person opened in it.
    private var confirmed: [String: String] = [:]
    /// Records a person asked to open in a new tab, until that tab's page is
    /// made (its key is not known before): record URL -> when it was asked.
    private var openingByPerson: [String: Date] = [:]
    /// Open Mac tabs, for renames and quitting.
    private let tabs = NSHashTable<MacScreenPageTab>.weakObjects()
    private var termination: (any NSObjectProtocol)?
    /// How long a person's new-tab request may wait for its page.
    static let openingWindow: TimeInterval = 5

    public init(store: MacScreenStore) {
        self.store = store
        host = MacScreenShareHost(store: store)
        store.onRenamed = { [weak self] id, name in
            for tab in self?.tabs.allObjects ?? [] where tab.record.macID == id { tab.rename(name) }
        }
        store.onForgotten = { [weak self] id in
            for tab in self?.tabs.allObjects ?? [] where tab.record.macID == id { tab.pane?.forgotten() }
        }
        // Quitting ends every session now, so the other Mac stops showing a viewer at once.
        termination = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { // main-proof: observer on queue: .main
                for tab in self?.tabs.allObjects ?? [] { tab.pane?.close() }
            }
        }
    }

    /// At launch: Share This Mac resumes when the person left it on.
    public func activate() {
        Task { [weak self] in
            await self?.store.load()
            self?.host.activate()
        }
    }

    /// A person opened or confirmed `url` in the tab `key` (`byPerson` false: ignored).
    public func confirm(_ key: String, url: URL, byPerson: Bool) {
        guard byPerson else { return }
        confirmed[key] = url.absoluteString
    }

    /// The tab `key` closed or left the Mac Screen page.
    public func forget(_ key: String) { confirmed[key] = nil }

    /// Saves the Mac a `cmux-vnc://pair` link names.
    public func pair(link: URL) -> MacScreenRecord? {
        guard case let .success(mac) = store.add(link: link.absoluteString) else { return nil }
        return MacScreenRecord(macID: mac.id)
    }

    /// The page for the record at `url` in the tab `key`. `show` replaces
    /// this tab's page; `newTab` opens a tab beside it (false when refused).
    public func makePage(url: URL, key: String, engine: BrowserEngineKind, profile: BrowserProfileID, isLocal: Bool,
                         show: @escaping @MainActor (URL) -> Void, newTab: @escaping @MainActor (URL) -> Bool,
                         closeTab: @escaping @MainActor () -> Void) -> MacScreenPageTab {
        let id = BrowserTabID(rawValue: key)
        let record = MacScreenRecord(url: url) ?? MacScreenRecord(macID: nil)
        let page: MacScreenPageTab
        if let macID = record.macID {
            let tab = MacScreenPageTab(id: id, engine: engine, profile: profile, record: record)
            tabs.add(tab)
            // A person's open is matched now, while it is fresh; the pane waits for the saved Macs.
            let person = takePersonOpen(url: url, key: key)
            Task { [weak self, weak tab] in
                guard let self else { return }
                await store.load()
                tab?.install(makePane(macID: macID, url: url, key: key, isLocal: isLocal, person: person, show: show, closeTab: closeTab))
            }
            page = tab
        } else {
            Task { [weak self] in await self?.store.load() }
            var actions = MacScreenHomeActions()
            actions.open = { [weak self] mac in
                let target = MacScreenRecord(macID: mac).url
                self?.confirm(key, url: target, byPerson: true)
                show(target)
            }
            actions.openInNewTab = { [weak self] mac in
                let target = MacScreenRecord(macID: mac).url.absoluteString
                self?.openingByPerson[target] = Date()
                if !newTab(MacScreenRecord(macID: mac).url) { self?.openingByPerson[target] = nil }
            }
            let home = NSHostingView(rootView: MacScreenHomeView(store: store, host: host, actions: actions))
            // The page fills the tab; its content never sizes the tab's layout.
            home.sizingOptions = []
            page = MacScreenPageTab(id: id, engine: engine, profile: profile, home: home)
        }
        // Another Mac Screen record (CLI navigate, a link) shows in this tab, unconfirmed.
        page.onShowRecord = show
        return page
    }

    /// Whether a person opened `url` in the tab `key` (consumes a new-tab request).
    private func takePersonOpen(url: URL, key: String) -> Bool {
        let now = Date()
        openingByPerson = openingByPerson.filter { now.timeIntervalSince($0.value) < Self.openingWindow }
        if openingByPerson.removeValue(forKey: url.absoluteString) != nil { confirmed[key] = url.absoluteString }
        return confirmed[key] == url.absoluteString
    }

    private func makePane(macID: UUID, url: URL, key: String, isLocal: Bool, person: Bool, show: @escaping @MainActor (URL) -> Void,
                          closeTab: @escaping @MainActor () -> Void) -> MacScreenPane {
        let pane: MacScreenPane
        if let mac = store.mac(macID), let pairing = store.pairing(for: macID) {
            let person = isLocal && (person || confirmed[key] == url.absoluteString)
            pane = MacScreenPane(name: mac.name, pairing: pairing, preferences: mac.preferences, confirmed: person)
            pane.session?.hostID = macID
            #if DEBUG
            if relayOnly { pane.setRelayOnly(true) }
            #endif
            pane.handlers.confirm = { [weak self] in self?.confirmed[key] = url.absoluteString }
            pane.handlers.connected = { [weak self] preferences in self?.store.connected(macID, preferences: preferences) }
            pane.handlers.preferencesChanged = { [weak self] preferences in self?.store.update(macID, preferences: preferences) }
        } else {
            pane = MacScreenPane(missingMac: ())
        }
        pane.handlers.closeTab = closeTab
        pane.handlers.openHome = { show(MacScreenRecord.homeURL) }
        pane.handlers.isLocalShortcut = { [weak self] event in self?.isLocalShortcut(event) ?? false }
        return pane
    }
}

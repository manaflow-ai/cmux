import AppKit
import CmuxNextActions
import CmuxNextBridge
import CmuxNextBrowser
import CmuxNextMacScreen
import Foundation
import SwiftUI

/// Mac Screen tabs (`cmux://mac-screen`): the saved Macs and Share This Mac
/// (`MacScreenStore`, `MacScreenShareHost`), opening the home page, and
/// making each tab's page. A tab connects only when a person opened it in
/// this process (a click, the address bar, the palette); tabs that
/// automation opened, or that were restored, wait for Connect.
@MainActor
final class MacScreenPageService {
    private unowned let services: AppServices
    let store: MacScreenStore
    let host: MacScreenShareHost
    /// Tab key -> the record URL a person opened in it.
    private var confirmed: [String: String] = [:]
    /// Records a person asked to open in a new tab (its key is not known yet).
    private var openingByPerson: Set<String> = []

    init(services: AppServices) {
        self.services = services
        store = MacScreenStore.forApplication(bundleIdentifier: services.environment.launch.bundleID)
        host = MacScreenShareHost(store: store)
    }

    /// At launch: Share This Mac resumes when the person left it on.
    func activate() {
        host.activate()
    }

    /// Selects the active window's Mac Screen home tab, else opens one beside
    /// the focused tab.
    func open() {
        guard let window = services.windows.active else { return services.registry.refuse(RefusalStrings.noWindowOpen) }
        for pane in window.content?.panes.values.map({ $0 }) ?? [] {
            if let tab = pane.pane.tabs.first(where: { tab in
                tab.url.flatMap(URL.init(string:)).flatMap(MacScreenRecord.init(url:)).map { $0.macID == nil } == true
            }) {
                pane.select(StripTabID(tab.id))
                return
            }
        }
        guard let pane = window.focusedPane else { return }
        pane.newBrowserTab(url: MacScreenRecord.homeURL)
    }

    /// A person opened or confirmed `url` in the tab `key`. Ignored inside an
    /// action run a person did not start (CLI, MCP, scripts, remote).
    func confirm(_ key: String, url: URL, scope: ActionRunScope? = ActionRunScope.current) {
        guard RemoteViewPageService.isPersonInput(scope) else { return }
        confirmed[key] = url.absoluteString
    }

    func forget(_ key: String) { confirmed[key] = nil }

    /// Saves the Mac a `cmux-vnc://pair` link names (typed in an address bar).
    func pair(link: URL) -> MacScreenRecord? {
        guard case let .success(mac) = store.add(link: link.absoluteString) else { return nil }
        return MacScreenRecord(macID: mac.id)
    }

    /// Whether a key down on a Mac Screen stays in cmux: its own shortcuts
    /// (new tab, close tab, switching panes) do; the clipboard and undo
    /// chords go to the other Mac, where the selection is.
    static func staysLocal(_ event: NSEvent, registry: ActionRegistry) -> Bool {
        guard registry.resolveShortcut(for: event) != nil else { return false }
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let editing: Set<String> = ["c", "v", "x", "a", "z"]
        if flags == .command || flags == [.command, .shift], let key = event.charactersIgnoringModifiers?.lowercased(), editing.contains(key) {
            return false
        }
        return true
    }

    /// The page for the record at `url` in the tab `key`.
    func makePage(url: URL, key: String, engine: BrowserEngineKind, profile: BrowserProfileID, isLocal: Bool,
                  show: @escaping @MainActor (URL) -> Void, newTab: @escaping @MainActor (URL) -> Void,
                  closeTab: @escaping @MainActor () -> Void) -> MacScreenPageTab {
        let id = BrowserTabID(rawValue: key)
        let record = MacScreenRecord(url: url) ?? MacScreenRecord(macID: nil)
        guard let macID = record.macID else {
            var actions = MacScreenHomeActions()
            actions.open = { [weak self] mac in
                let target = MacScreenRecord(macID: mac).url
                self?.confirm(key, url: target)
                show(target)
            }
            actions.openInNewTab = { [weak self] mac in
                let target = MacScreenRecord(macID: mac).url
                self?.openingByPerson.insert(target.absoluteString)
                newTab(target)
            }
            return MacScreenPageTab(id: id, engine: engine, profile: profile,
                                    home: NSHostingView(rootView: MacScreenHomeView(store: store, host: host, actions: actions)))
        }
        let pane: MacScreenPane
        if let mac = store.mac(macID), let pairing = store.pairing(for: macID) {
            if openingByPerson.remove(url.absoluteString) != nil { confirmed[key] = url.absoluteString }
            let person = isLocal && confirmed[key] == url.absoluteString
            pane = MacScreenPane(name: mac.name, pairing: pairing, preferences: mac.preferences, confirmed: person)
            pane.session?.hostID = macID
            pane.handlers.confirm = { [weak self] in self?.confirmed[key] = url.absoluteString }
            pane.handlers.connected = { [weak self] preferences in self?.store.connected(macID, preferences: preferences) }
            pane.handlers.preferencesChanged = { [weak self] preferences in self?.store.update(macID, preferences: preferences) }
        } else {
            pane = MacScreenPane(missingMac: ())
        }
        pane.handlers.closeTab = closeTab
        pane.handlers.openHome = { show(MacScreenRecord.homeURL) }
        pane.handlers.isLocalShortcut = { [weak services] event in services.map { Self.staysLocal(event, registry: $0.registry) } ?? false }
        return MacScreenPageTab(id: id, engine: engine, profile: profile, record: record, pane: pane)
    }
}

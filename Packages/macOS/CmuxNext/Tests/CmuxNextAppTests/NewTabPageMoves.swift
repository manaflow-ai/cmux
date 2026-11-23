import AppKit
@testable import CmuxNextAgentPane
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextTestSupport
import CmuxNextWakeups
import Foundation
import Testing

/// A print-only tool of a row: who asked the tab store for each page view, and which tab lost its page view to
/// which tab. It wraps the store's build hook (`AgentTabStore.onPageBuilt`) and the store's ask to the panes for a
/// page view that a tab gave away (`AgentTabStore.idlePanes.letGo`). Each event is one line (`lines`), with its time
/// since the tool's start.
///
/// Who asked is read from the call stack of the event: the names of the app's functions in it, nearest first.
/// A tab has a number in the order of first sight, the name that the row gave it, and its place in the windows.
@MainActor final class PageMoves {
    private let services: AppServices
    private let wiredBuilt: ((String) -> Void)?
    private let wiredPanes: (draws: (String, PaneController?) -> Bool, letGo: (String) -> Void)
    private let start = ContinuousClock.now
    private var seen: [AgentPaneView]
    private var had: [String: AgentPaneView] = [:]
    private var ids: [String: Int] = [:]
    private var names: [String: String] = [:]
    private var next = 1
    private(set) var lines: [String] = []

    init(_ services: AppServices) {
        let tabs = services.agentTabs, hook = tabs.onPageBuilt, panes = tabs.idlePanes
        self.services = services
        wiredBuilt = hook
        wiredPanes = panes
        seen = tabs.views.values.map { $0 }
        sync()
        tabs.onPageBuilt = { [weak self] key in
            self?.built(key)
            hook?(key)
        }
        tabs.idlePanes = (draws: panes.draws, letGo: { [weak self] key in
            self?.lost(key)
            panes.letGo(key)
        })
    }

    /// Puts the store's own hooks back. A row calls it after each wrapper that it put on top of this tool is gone.
    func restore() {
        services.agentTabs.onPageBuilt = wiredBuilt
        services.agentTabs.idlePanes = wiredPanes
    }

    /// Reads which tab has which page view now.
    func sync() {
        had = [:]
        for entry in services.agentTabs.views.entries { had[entry.key.key] = entry.value }
    }

    /// The row's name for tab `key`.
    func name(_ key: String, _ name: String) {
        names[key] = name
        names[services.agentTabs.resolve(key)] = name
    }

    static func seconds(_ time: Duration) -> Double {
        Double(time.components.seconds) + Double(time.components.attoseconds) / 1e18
    }

    private var stamp: String { String(format: "+%.3f s", Self.seconds(ContinuousClock.now - start)) }

    /// Where the windows have tab `key` now.
    func place(_ key: String) -> String {
        let now = services.agentTabs.resolve(key)
        for controller in services.windows.controllers {
            var contents: [(what: String, content: WorkspaceContentController)] = []
            // At a swap the window parks the workspace that it leaves before it makes the next one's content.
            if let shown = controller.content { contents.append((what: shown.isParked ? "the workspace that the window leaves now (parked)" : "the shown workspace", content: shown)) }
            if let ahead = controller.reservedContent.ready { contents.append((what: "the window's made-ahead content", content: ahead)) }
            for parked in controller.parked.values { contents.append((what: "a parked workspace", content: parked)) }
            for entry in contents {
                let panes = entry.content.panes.values
                if panes.contains(where: { $0.currentTabKey == key || $0.currentTabKey == now }) {
                    return "a pane of \(entry.what) has it selected"
                }
                if panes.contains(where: { pane in pane.orderedIDs.contains { $0.rawValue == key || $0.rawValue == now } }) {
                    return "a pane of \(entry.what) has it, not selected"
                }
            }
        }
        return "no pane of a window has it"
    }

    /// The tool's words for tab `key`: its number, the row's name for it, and what it is now.
    func label(_ key: String) -> String {
        let now = services.agentTabs.resolve(key)
        let id: Int
        if let known = ids[key] ?? ids[now] {
            id = known
        } else {
            id = next
            next += 1
        }
        ids[key] = id
        ids[now] = id
        var what: [String] = []
        if let name = names[key] ?? names[now] { what.append(name) }
        let ahead = services.daemon.store.reservedWorkspace?.tabKey
        if ahead == key || ahead == now { what.append("the tab of the store's made-ahead workspace") }
        if now.hasPrefix(ProvisionalTab.idPrefix) { what.append("the daemon did not answer its creation yet") }
        what.append(place(key))
        return "tab \(id) (\(what.joined(separator: "; ")))"
    }

    /// The names that `asker` looks for in the call stack.
    static let hints = ["reserveWorkspace", "showWorkspace", "idlePage", "warmPage", "loadOnHover", "NewTabPage", "PaneController",
                        "WorkspaceContentController", "reservedContent", "WorkspaceSpareSlot", "WindowController", "releaseGoneTabs", "rekey",
                        "TabContentCache", "Hibernation", "NewTabSparePool", "AgentPaneSpareRefiller", "ActionRegistry", "KeyRouter",
                        "FrameBatchQueue", "DaemonStore"]

    /// The symbols of the call stack now that are not this test target's, nearest first.
    static func stack() -> [String] {
        Thread.callStackSymbols.compactMap { frame -> String? in
            let parts = frame.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count > 3 else { return nil }
            let symbol = String(parts[3])
            return symbol.contains("CmuxNextAppTests") ? nil : symbol
        }
    }

    /// Who asked: the names of `hints` that the call stack has, nearest first, and the first symbols of the app in it.
    static func asker() -> String {
        let symbols = stack()
        var found: [String] = []
        for symbol in symbols {
            for hint in hints where symbol.contains(hint) && !found.contains(hint) { found.append(hint) }
        }
        let app = symbols.filter { $0.contains("CmuxNext") }.prefix(6).map { String($0.prefix(72)) }
        return "\(found), the stack: \(app)"
    }

    private func built(_ key: String) {
        let view = services.agentTabs.existingView(key)
        let new = view.map { view in !seen.contains { $0 === view } } ?? false
        if let view, new { seen.append(view) }
        let index = lines.count
        lines.append("\(stamp): the build hook: \(new ? "a NEW page view" : "a page view that the store had") for \(label(key)), asked by \(Self.asker())")
        sync()
        // The store reserves the made-ahead workspace after it built that workspace's page view, in the same turn.
        Task { @MainActor [weak self] in
            guard let self else { return }
            lines[index] += "; at the turn after it is \(label(key))"
            sync()
        }
    }

    private func lost(_ key: String) {
        let view = had[key] ?? had[services.agentTabs.resolve(key)]
        let drawn = services.cache.isRendering(key)
        let index = lines.count
        lines.append("\(stamp): \(label(key)) LOST its page view (the surface ledger says that a pane draws the tab: \(drawn)), asked by \(Self.asker())")
        Task { @MainActor [weak self] in
            guard let self else { return }
            sync()
            let taker = view.flatMap { view in self.had.first { $0.value === view }?.key }
            let words = taker.map { self.label($0) } ?? "no tab of the store"
            lines[index] += "; at the turn after the page view is with \(words)"
        }
    }
}

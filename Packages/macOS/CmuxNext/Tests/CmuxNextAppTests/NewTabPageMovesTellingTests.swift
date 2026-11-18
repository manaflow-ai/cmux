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
    private let wiredPanes: (draws: (String) -> Bool, letGo: (String) -> Void)
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
            if let shown = controller.content { contents.append((what: "the shown workspace", content: shown)) }
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

/// Telling rows, print only: they want nothing. A page that joins the New Tab pages after the fill of the palette's
/// actions was asked for (the flow of `NewTabOpenFramesTests.cmdNsFirstPageGetsThePalettesActions`) waits for those
/// actions. The row prints how long it waited, the tasks of the lister, the background tasks before the lister's
/// first task, and each page view event of `PageMoves`. It runs 2 times: with the app's New Tab pages as they are,
/// and with each of them marked as used (then no tab takes the page view of another tab).
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"),
                  .closesItsWindows)
struct NewTabPageMovesTellingTests {
    static func at(_ seconds: Double?) -> String { seconds.map { String(format: "+%.1f s", $0) } ?? "no time" }

    @Test(arguments: [false, true]) func aFirstPageWaitsForThePalettesActions(usedPages: Bool) async throws {
        try await PasswordManagerRouteTests.withApp { services, _ in
            services.agentTabs.localHost = AgentSessionRef.host(installID: "cn-page-moves-telling-\(usedPages ? "used" : "idle")")
            try #require(services.agentTabs.canHostChat, "this build has no New Tab page")
            let tabs = services.agentTabs, budget = services.mainWork.budget, pool = services.newTabSpares
            BenchSpans.begin()
            let clock = ContinuousClock.now, atStart = budget.stats
            let moves = PageMoves(services)
            defer { moves.restore() }
            let (_, pane) = try await NewTabOpenFramesTests.focusedPane(services)
            let first = pane.currentTabKey
            if let first { moves.name(first, "the app's first tab") }
            let firstView = first.flatMap { tabs.existingView($0) }
            if usedPages { NewTabOpenFramesTests.useEachNewTabPage(services) }
            let aheadBefore = services.daemon.store.reservedWorkspace != nil
            let asked = PageMoves.seconds(ContinuousClock.now - clock)
            let made = try #require(tabs.firstPage(cwd: nil, token: nil), "no first page")
            let key = "page-moves-telling-\(UUID().uuidString.prefix(8))"
            tabs.newTabPages[key] = made
            defer { tabs.newTabPages[key] = nil }
            moves.name(key, "the row's own page, with no tab")
            var samples: [(at: Double, background: Int)] = []
            var spares: [AgentPaneView] = []
            var came: Double?
            while came == nil, ContinuousClock.now - clock < .seconds(40) {
                moves.sync()
                let at = PageMoves.seconds(ContinuousClock.now - clock)
                samples.append((at: at, background: budget.stats.tasks[2] - atStart.tasks[2]))
                if let spare = pool.spare?.view, !spares.contains(where: { $0 === spare }) { spares.append(spare) }
                if tabs.newTabPages[key]?.page.omnibar.actions.isEmpty == false {
                    came = at
                } else {
                    try await Task.sleep(for: .milliseconds(50))
                }
            }
            let slices = BenchSpans.end().filter { $0.name == "newTab.paletteActions" }.map { $0.start / 1000 }
            let stats = budget.stats
            let firstSlice = slices.min(), lastSlice = slices.max()
            let before = firstSlice.flatMap { slice in samples.last(where: { $0.at <= slice })?.background }
            let beforeWords = before.map { "\($0)" } ?? "not known"
            let cameWords = came.map { String(format: "after %.1f s", $0 - asked) } ?? "not in 40 s"
            let firstNow = first.flatMap { tabs.existingView($0) }
            let same = firstView != nil && firstView === firstNow
            let aheadAfter = services.daemon.store.reservedWorkspace != nil
            let background = stats.tasks[2] - atStart.tasks[2], frames = stats.frames - atStart.frames
            let idleWaits = stats.waitedForIdleFrame - atStart.waitedForIdleFrame
            print("""
                NewTabPageMovesTellingTests: a first page and the palette's actions, the app's New Tab pages \
                \(usedPages ? "marked as used" : "as they are"): the actions came \(cameWords) (the row asked at \(Self.at(asked))); \
                the lister ran \(slices.count) tasks, the first at \(Self.at(firstSlice)), the last at \(Self.at(lastSlice)); \
                background tasks before the lister's first task: \(beforeWords), in all: \(background); frames: \(frames); \
                waits for a frame with idle time: \(idleWaits); the store had a made-ahead workspace before the row asked: \
                \(aheadBefore), at the end: \(aheadAfter); page views of the pool seen: \(spares.count); the app's first tab \
                had a page view at the start: \(firstView != nil), at the end: \(firstNow != nil), the same one: \(same); \
                the page views, each event: \(moves.lines)
                """)
        }
    }
}

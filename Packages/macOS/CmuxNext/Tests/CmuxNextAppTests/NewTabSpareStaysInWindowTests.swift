import AppKit
import CmuxNextActions
@testable import CmuxNextAgentPane
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextTestSupport
import Foundation
import Testing

/// CMD-T BUDGET 2, cause (b) (2026-11-10): a Cmd-T that takes a New Tab page the pool got back from a Cmd-W paid
/// 19-23 ms in the key's turn, a first-use Cmd-T about 1 ms, for the same view insert (`PaneContentView.install`).
/// The closed page left the window in the close's turn and the pool put it back only after 750 ms with no input
/// (R81), so in a run of Cmd-T and Cmd-W the pool handed out a page that was in no window (`debug.new_tab`:
/// `window: null`), and the key's turn attached a WKWebView to the window.
///
/// The count: a run of Cmd-W + Cmd-T pairs with no quiet time between them (the test never gives up its turn, so no
/// timer of the pool runs). For each press: is the page that the pool hands out in the window, in the pool's parking
/// view. The number of pairs is the one argument; the answer must be 0 presses outside the window for every size.
@MainActor @Suite(.serialized)
struct NewTabSpareStaysInWindowTests {
    private static func tree() -> DaemonTree {
        let pane = PaneSnapshot(id: PaneID(rawValue: 1), tabs: [TabSnapshot(surface: SurfaceID(rawValue: 1), title: "~")])
        let screen = ScreenSnapshot(id: ScreenID(rawValue: 1), layout: .leaf(pane.id), panes: [pane])
        var tree = DaemonTree(registryID: "s-local", workspaces: [
            WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: WorkspaceKey(rawValue: "spare-window-ws"), name: "spare", screens: [screen]),
        ])
        tree.personal = PersonalState(workspaces: [PersonalWorkspace(sessionID: "s-local", workspaceKey: WorkspaceKey(rawValue: "spare-window-ws"), index: 0)])
        return tree
    }

    /// What one press found: the page it took, whether that page was in the window, and whether it was in the pool's
    /// parking view (a direct child of the window's content view).
    private struct Press {
        var samePage: Bool
        var inWindow: Bool
        var inParking: Bool
        /// After the pool took the closed page: the window's first responder is in that page.
        var keptKeyboard = false
        /// Why the pool refused the page that the close before this press gave it; nil: it took the page.
        var refusal: String?
    }

    /// What the shown New Tab page asks of the app's tip records (`tips.state`) before its tab closes: it reads
    /// them and asks for the one-time Cloud hint by itself, as each New Tab page of a default profile does when the
    /// hint is due (webviews App.tsx, `claimCloudHint`; the person did nothing). With `closesTheHint` the person
    /// then closes the hint with its X (`tips.state {id, state: closed}`).
    private static func tipTraffic(closesTheHint: Bool) -> [AgentPaneFeatureTipRequest] {
        [.read, .claim(id: "cloud-chat", feature: nil)] + (closesTheHint ? [.keep(id: "cloud-chat", state: "closed")] : [])
    }

    /// A view that takes the keyboard, as a field of the page does.
    private final class KeyTaker: NSView {
        override var acceptsFirstResponder: Bool { true }
    }

    /// `pairs` times: the pane closes its untouched New Tab page (its strip update drops the page, then the tab's
    /// release gives the page to the pool), then a press takes the pool's spare and the pane shows it.
    ///
    /// `releasedWithTheKeyboard`: the other order of a close. The tab's release comes BEFORE its pane's strip update
    /// (a tab that the CLI, an agent or another device closed: `releaseGoneTabs`), while the page shows and holds the
    /// keyboard. The pool then moves the page out of its pane itself.
    ///
    /// `tips`: before each close the shown page sends this tip traffic, as a page of a default profile (Show Feature
    /// Tips on) does. A refusal of the pool is then counted (`Press.refusal`) and the press opens a cold page, as the
    /// app does; with no tip traffic a refusal is a fault of the fixture.
    private static func presses(pairs: Int, releasedWithTheKeyboard: Bool = false, tips: [AgentPaneFeatureTipRequest]? = nil) async throws -> [Press] {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        services.windows.ordersWindowsIn = false
        let store = services.machines.local.store
        let identity = try JSONDecoder().decode(DaemonIdentity.self, from: Data(#"{"app":"cmux-tui","protocol":1,"session":"s-local","generation":"g1"}"#.utf8))
        store.noteHandshake(identity)
        store.connectionState = .connected(identity)
        store.apply(snapshot: tree())
        let controller = try #require(services.windows.openWindow(workspaces: ["spare-window-ws"], frame: CGRect(x: 200, y: 200, width: 1100, height: 720)))
        let folder = FileManager.default.temporaryDirectory.appending(path: "spare-window-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let pool = services.newTabSpares
        var pages: [AgentPaneView] = []
        // The tip records of this run only: a fresh install's (no record, the 14-day budget open), never the defaults of the test process.
        let tipSuite = "NewTabSpareStaysInWindowTests.\(UUID().uuidString)"
        let tipDefaults = try #require(UserDefaults(testSuiteName: tipSuite))
        tipDefaults.removePersistentDomain(forName: tipSuite)
        defer {
            pool.makeSpare = nil
            pool.dropAll()
            pages.forEach { $0.close() }
            controller.teardown()
            controller.window?.close()
            try? FileManager.default.removeItem(at: folder)
            tipDefaults.removePersistentDomain(forName: tipSuite)
        }
        for _ in 0..<200 where controller.workspaceContent?.panes.count != 1 { try await Task.sleep(for: .milliseconds(10)) }
        let content = try #require(controller.workspaceContent)
        content.contentView.layoutSubtreeIfNeeded()
        let window = try #require(controller.window)
        let pane = try #require(content.panes.values.first)

        // An inert page stands in for WebKit's (as `NewTabRapidPairTests.filledPool`): loaded and painted.
        let html = folder.appending(path: "index.html")
        try Data("<html><body>New Tab spare fixture</body></html>".utf8).write(to: html)
        let made: (AgentPaneNewTab) -> AgentPaneView? = { page in
            let model = AgentPaneModel(host: services.agentTabs.host, newTab: page)
            guard let view = AgentPaneView(model: model, source: .bundled(html)) else { return nil }
            model.featureTipRecords = AgentPaneFeatureTipRecords(defaults: tipDefaults)
            model.hasHandshake = true
            model.markPainted()
            view.redraw.nextFrameOverride = { body in body() }
            return view
        }
        pool.dropAll()
        pool.capacity = 2
        pool.makeSpare = made // a timer of the pool that runs after the test makes no real page
        pool.retarget(window)
        try #require(pool.target === window, "fixture: the pool has no target window")
        try #require(pool.spares.isEmpty, "fixture: the pool holds \(pool.spares.count) spares before the run")

        // The pane shows an untouched New Tab page, as after a Cmd-T. From here on the test keeps its turn.
        let first = try #require(made(NewTabPage.sparePage(services)), "fixture: no page")
        pages.append(first)
        pane.view.install(first)
        try #require(first.window === window, "fixture: the page is not in the window")
        var shown = first
        var presses: [Press] = []
        for pair in 1...pairs {
            var keptKeyboard = false
            var refusal: String?
            for request in tips ?? [] { _ = await shown.model.respond(to: .featureTips(request)) }
            if releasedWithTheKeyboard {
                let taker = KeyTaker(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
                shown.addSubview(taker)
                let took = window.makeFirstResponder(taker)
                let holds = took && window.firstResponder === taker
                try #require(holds, "fixture: pair \(pair): the page did not take the keyboard")
                try #require(pool.recycle(shown), "fixture: pair \(pair): the pool refused the shown page (\(pool.lastRecycleRefusal ?? "no reason"))")
                keptKeyboard = (window.firstResponder as? NSView)?.isDescendant(of: shown) ?? false
                if window.firstResponder === taker { window.makeFirstResponder(nil) }
                taker.removeFromSuperview()
                pane.view.dropClosedParked { [] } // the strip update, after the release
            } else {
                // Cmd-W: the strip update retires the page and drops it as closed; then the tab's release offers it to the pool.
                pane.view.retire(shown)
                pane.view.dropClosedParked { [] }
                if !pool.recycle(shown) {
                    refusal = pool.lastRecycleRefusal ?? "no reason"
                    try #require(tips != nil, "fixture: pair \(pair): the pool refused the closed page (\(refusal ?? ""))")
                }
            }
            // Cmd-T: the pool hands out its oldest spare and the pane shows it. With no spare (the pool refused the
            // closed page) the press makes a cold page, as the app does.
            let spare = pool.take(for: window, size: NewTabSparePool.newTabContentSize(in: pane))?.view
            try #require(spare != nil || refusal != nil, "fixture: pair \(pair): the pool had no spare")
            let taken = try #require(spare ?? made(NewTabPage.sparePage(services)), "fixture: pair \(pair): no page")
            presses.append(Press(samePage: taken === shown, inWindow: taken.window === window,
                                 inParking: taken.superview != nil && taken.superview?.superview === window.contentView,
                                 keptKeyboard: keptKeyboard, refusal: refusal))
            pane.view.install(taken)
            try #require(taken.superview === pane.view.contentHost, "fixture: pair \(pair): the pane does not show the page")
            if !pages.contains(where: { $0 === taken }) { pages.append(taken) }
            shown = taken
        }
        return presses
    }

    @Test(.timeLimit(.minutes(2)), arguments: [1, 3, 12])
    func noRapidPressTakesAPageThatLeftTheWindow(pairs: Int) async throws {
        let presses = try await Self.presses(pairs: pairs)
        try #require(presses.count == pairs, "fixture: \(presses.count) presses, not \(pairs)")
        let report = presses.enumerated().map { "\($0.offset + 1):\($0.element.inWindow ? "window" : "null")" }.joined(separator: " ")
        print("spare per press, \(pairs) pairs: \(report)")
        let other = presses.filter { !$0.samePage }.count
        #expect(other == 0, "\(other) of \(pairs) presses did not get the page that was closed (the pool made or kept another one)")
        let outside = presses.filter { !$0.inWindow }.count
        #expect(outside == 0, """
            \(outside) of \(pairs) presses took a spare that was in no window (`window: null`): the key's turn attaches \
            a WKWebView to the window (19-23 ms) where a first-use press moves it inside the window (1 ms): \(report)
            """)
        let elsewhere = presses.filter { !$0.inParking }.count
        #expect(elsewhere == 0, "\(elsewhere) of \(pairs) presses took a spare that was not in the pool's parking view: the key's view insert depends on the spare's history")
    }

    /// CMD-T BUDGET 3 (2026-11-10): on a default profile (Show Feature Tips on) the pool refused EVERY closed New Tab
    /// page as "touched by featureTips" (5 of 5 Cmd-W in a hold on a new profile), so no closed page went back to the
    /// pool and each Cmd-W cost one cold page (about 14 ms on the main thread) in the path of the next Cmd-T. The
    /// page had only asked the app for the one-time Cloud hint (a tip claim that the page sends by itself); the
    /// person had done nothing in it. A claim, and the X of a hint, change the app's tip records and no state of
    /// the page that an adoption keeps.
    ///
    /// The count: a run of Cmd-W + Cmd-T pairs, each closed page sent the tip traffic first. For every size, with
    /// and without the X of the hint: 0 closes refused, and each press gets the page that was closed.
    @Test(.timeLimit(.minutes(2)), arguments: [1, 3, 12], [false, true])
    func aPageThatOnlyAskedForATipGoesBackToThePool(pairs: Int, closesTheHint: Bool) async throws {
        let tips = closesTheHint ? "a claim, then the X of the hint" : "a claim"
        let presses = try await Self.presses(pairs: pairs, tips: Self.tipTraffic(closesTheHint: closesTheHint))
        try #require(presses.count == pairs, "fixture: \(presses.count) presses, not \(pairs)")
        let refusals = presses.compactMap(\.refusal)
        print("tip traffic (\(tips)), \(pairs) pairs: \(refusals.count) refusals \(Set(refusals).sorted())")
        #expect(refusals.isEmpty, """
            \(refusals.count) of \(pairs) closed New Tab pages were refused by the pool (\(Set(refusals).sorted().joined(separator: "; "))) \
            after tip traffic (\(tips)): each of these Cmd-W costs one cold page in the path of the next Cmd-T
            """)
        let other = presses.filter { !$0.samePage }.count
        #expect(other == 0, "\(other) of \(pairs) presses did not get the page that was closed (a cold page was made in the key's turn)")
        let outside = presses.filter { !$0.inWindow || !$0.inParking }.count
        #expect(outside == 0, "\(outside) of \(pairs) presses took a page that was not in the parking view of the window")
    }

    /// A page that the pool moves out of its pane is out of sight (the parking view is off screen, the page is a
    /// spare): it must not hold the keyboard, or the person's next keys go into a page nobody sees, and the next
    /// Cmd-T shows that page with those keys in it. The removal from the window that the move replaces took the
    /// keyboard away; the move must do the same.
    @Test(.timeLimit(.minutes(2)), arguments: [1, 3])
    func aPageThePoolMovesOutOfItsPaneGivesUpTheKeyboard(pairs: Int) async throws {
        let presses = try await Self.presses(pairs: pairs, releasedWithTheKeyboard: true)
        try #require(presses.count == pairs, "fixture: \(presses.count) presses, not \(pairs)")
        let kept = presses.filter { $0.keptKeyboard }.count
        #expect(kept == 0, "\(kept) of \(pairs) pages that the pool moved into its parking view kept the keyboard: keys go into a hidden spare page")
        let outside = presses.filter { !$0.inWindow || !$0.inParking }.count
        #expect(outside == 0, "\(outside) of \(pairs) presses took a spare that was not in the parking view of the window")
    }
}

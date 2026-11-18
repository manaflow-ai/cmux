import AppKit
@testable import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextTestSupport
import Foundation
import Testing

/// SHORTCUT FRAMES F2 (Lawrence 2026-11-02: "open the new tab instantly, the frame of ... pixel perfect"). A 120 Hz
/// video of Cmd-T (feat 1cb7548, cmux22) showed the spare's own screen in the first frame ("Choose folder"), then the
/// adopted page remounted with the tab's folder, then the folder's trust card came: the content moved twice after the
/// key. The parked spare must already draw the New Tab context a Cmd-T in its window gives (the focused pane's folder),
/// so the adoption changes no screen and the first frame is the final one.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"),
                  .closesItsWindows)
struct NewTabSpareContextTests {
    /// What a New Tab context draws: all of it but the key's input token, the bar's places (the page takes
    /// those in place, webviews newtab/adoption.ts `sameNewTabScreen`) and the warm chat list (read at load only).
    static func screen(_ page: AgentPaneNewTab?) -> AgentPaneNewTab? {
        guard var page else { return nil }
        (page.inputToken, page.warm) = (nil, nil)
        page.omnibar = AgentPaneOmnibar()
        return page
    }

    @Test func theParkedSpareDrawsTheFocusedPanesContextBeforeCmdT() async throws {
        try await Self.withAPreparedSpare("cn-spare-context") { services, pane, spare, _ in
            // Cmd-T adopts it, and the screen it drew is the screen the tab gets: no remount after the key.
            let drawn = Self.screen(spare.model.newTab)
            NewTabPage.open(in: pane, seed: nil)
            #expect(services.newTabSpares.spare?.view !== spare, "Cmd-T did not adopt the parked spare")
            #expect(Self.screen(spare.model.newTab) == drawn, "the adoption changed the screen the spare drew before the key")
            #expect(!spare.model.newTabPrepared, "after Cmd-T the context is the tab's: its handshake may name its folder")
        }
    }

    /// The key's own work for a page that the pool prepared. The prepare gave the parked page the context that a
    /// Cmd-T in its window gives, and the page draws it. So the key's own turn must not send the page that context
    /// again: not the folder that the page draws and not the bar's places (the larger part of the context: the open
    /// tabs, the workspaces, the folders, the recent pages). And the key shows its tab one time in its own turn: each
    /// more show runs the pane's whole show again (the old tab's withdraw, the tab strip's sync, the content view).
    ///
    /// What this holds and what it does not: the scripts are those that the adopted page's own view was given in
    /// the key's call, which has no suspension, so no other page and no other suite adds to them. The shows are the
    /// app's own spans `switch.view` in that same call. A show at a frame after the key is not counted here: the
    /// span names no pane, and the suites share the main actor, so a count over a suspension is not this pane's
    /// alone. Nothing changes between the prepare and the key in this test: a field that changed must still reach
    /// the page, and no row here holds that.
    @Test func cmdTSendsAPreparedSpareNoContextThatItDrawsAndShowsItsTabOnce() async throws {
        try await Self.withAPreparedSpare("cn-spare-key-work") { services, pane, spare, keyPage in
            let folder = try #require(keyPage.cwd.map { URL(fileURLWithPath: $0).lastPathComponent }, "the key's page has no folder")
            var scripts: [String] = []
            spare.evaluateScript = { scripts.append($0) }
            let counted = Self.spans("switch.view") { NewTabPage.open(in: pane, seed: nil) }
            try #require(services.newTabSpares.spare?.view !== spare, "Cmd-T did not adopt the parked spare")
            let selectedPage = pane.stripModel.selectedID.flatMap { services.agentTabs.existingView($0.rawValue) }
            try #require(selectedPage === spare, "the pane's new tab does not have the parked spare as its page")
            let shows = try #require(counted, "the count of the key's shows is not whole")
            let drawnAgain = scripts.filter { $0.contains(folder) || $0.contains("\"omnibar\"") }
            print("key-work-of-test: NewTabSpareContextTests: \(scripts.count) scripts in the key's turn of \(scripts.map(\.utf8.count)) bytes, "
                + "\(drawnAgain.count) with the context that the page draws, \(shows) shows in the key's turn")
            #expect(drawnAgain.isEmpty,
                    "the key sent the prepared page \(drawnAgain.count) scripts with the context that it draws (\(drawnAgain.map(\.utf8.count)) bytes)")
            #expect(shows == 1, "the key showed its pane's selection \(shows) times in its own turn")
        }
    }

    /// The count of the app's spans `name` that `body` makes (`BenchSpans` has them while a bench records). `body`
    /// has no suspension, so the count is of `body` alone. A bench of another suite that records now (the suites
    /// share the main actor) keeps its record: this starts no second one. nil when the ring of spans filled
    /// meanwhile, so the count is not whole.
    private static func spans(_ name: String, in body: () -> Void) -> Int? {
        let had = BenchSpans.spans.count
        BenchSpans.mark("test.probe")
        let another = BenchSpans.spans.count > had
        if !another { BenchSpans.begin() }
        defer { if !another { _ = BenchSpans.end() } }
        let before = BenchSpans.spans.filter { $0.name == name }.count
        body()
        let after = BenchSpans.spans
        BenchSpans.mark("test.probe")
        guard BenchSpans.spans.count > after.count else { return nil }
        return after.filter { $0.name == name }.count - before
    }

    /// The app with one parked spare that the pool prepared: an inert page stands in for the web page, the pool's
    /// own parking, fitting and context work run, and the spare draws the context that a Cmd-T in the focused
    /// terminal pane gives. `body` gets that pane, the spare and the key's context.
    static func withAPreparedSpare(_ install: String,
                                   _ body: (AppServices, PaneController, AgentPaneView, AgentPaneNewTab) async throws -> Void) async throws {
        try await PasswordManagerRouteTests.withApp { services, _ in
            services.agentTabs.localHost = AgentSessionRef.host(installID: install)
            try #require(services.agentTabs.canHostChat, "this build has no New Tab page")
            try await PasswordManagerRouteTests.until({ !services.windows.registry.isLaunching }, within: .seconds(60))
            let controller = try #require(services.windows.active)
            let window = try #require(controller.window)
            window.orderFrontRegardless()
            let folder = FileManager.default.temporaryDirectory.appending(path: "sf-spare-\(UUID().uuidString.prefix(8))")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let html = folder.appending(path: "index.html")
            try Data("<html><body>New Tab spare fixture</body></html>".utf8).write(to: html)
            let pool = services.newTabSpares
            var made: [AgentPaneView] = []
            var loaded: [AgentPaneNewTab] = []
            defer {
                pool.makeSpare = nil
                pool.dropAll()
                made.forEach { $0.close() }
                try? FileManager.default.removeItem(at: folder)
            }
            let workspace = try await services.windows.createWorkspace(WorkspaceSpawn(cwd: folder.path, name: "sf-spare", command: "/bin/sh"),
                                                                       into: controller.state.id)
            services.windows.show(workspaceID: workspace, in: controller.state)
            @MainActor func focused() -> PaneController? { controller.content?.focusedPane }
            // The page's folder (NewTabPageMachine: the selected terminal's, else the workspace's first tab's) is set
            // once the daemon's tab names it: the selected tab's own cwd can come later (fleet run 0b87f88f0040).
            @MainActor func keyCwd() -> String? {
                focused().flatMap { NewTabPage.page(services, selected: $0.selectedTab, window: window, pane: $0, paletteActions: false).cwd }
            }
            // The workspace's terminal pane gets the focus: a docked agent chat column can hold it (fleet run d87741821d15:
            // the focused pane showed a conversation, so the page had no folder). The workspace runs a shell, so it has a
            // terminal even where a new workspace opens on the New Tab page (display worker, step 151622cdd9f4).
            @MainActor func terminalPane() -> PaneController? {
                controller.content?.panes.values.first { pane in pane.selectedTab?.kind == .pty }
            }
            try await PasswordManagerRouteTests.until({
                guard controller.state.workspaceID == workspace, let pane = terminalPane() else { return false }
                if focused() !== pane { controller.focus.send(.focusPane(pane.paneKey, source: .intent)) }
                return focused() === pane && keyCwd() != nil
            }, report: {
                "shows \(controller.state.workspaceID ?? "nil"), selected \(focused()?.selectedTab.map { String(describing: $0.kind) } ?? "nil"), "
                    + "tab cwd \(focused()?.selectedTab?.cwd ?? "nil"), page cwd \(keyCwd() ?? "nil")"
            })
            let pane = try #require(focused())

            // An inert page stands in for WebKit's: the pool's own parking, fitting and context work run.
            pool.dropAll()
            pool.makeSpare = { page in
                loaded.append(page)
                let model = AgentPaneModel(host: services.agentTabs.host, newTab: page)
                guard let view = AgentPaneView(model: model, source: .bundled(html)) else { return nil }
                made.append(view)
                return view
            }
            pool.retarget(window)
            pool.prewarm()
            pool.start()
            try await PasswordManagerRouteTests.until({ pool.spare != nil }, report: { "no spare was parked" })
            let spare = try #require(pool.spare?.view)
            // The pool prepares only a page that finished its handshake and first paint (an adopt event before
            // React listens is lost). The inert page has neither: the pool must leave it alone until then.
            try await PasswordManagerRouteTests.until({ pool.deferredPrepares > 0 }, report: { "the pool never looked at the parked spare" })
            #expect(spare.model.newTab?.cwd == nil, "the pool prepared a page that had no handshake and no first paint")
            spare.model.hasHandshake = true
            spare.model.markPainted()
            // It loads folderless: a spare's handshake keeps its load folder (the chat's start-folder roots), and
            // that folder must be no tab's; the tab's context comes after the load.
            #expect(loaded.allSatisfy { $0.cwd == nil }, "the spare loaded with folder \(loaded.compactMap(\.cwd))")

            // The context Cmd-T gives the page (NewTabPage.open): the focused pane's.
            let keyPage = NewTabPage.page(services, selected: pane.selectedTab, window: window, pane: pane, paletteActions: false)
            try #require(keyPage.cwd != nil, "the focused terminal has no folder for the page")
            try await PasswordManagerRouteTests.until({ Self.screen(spare.model.newTab) == Self.screen(keyPage) && spare.model.newTabPrepared },
                                                      within: .seconds(3),
                                                      report: {
                "the parked spare draws cwd \(spare.model.newTab?.cwd ?? "nil"), home \(spare.model.newTab?.home ?? "nil"); "
                    + "Cmd-T gives cwd \(keyPage.cwd ?? "nil"), home \(keyPage.home ?? "nil")"
            })
            try await body(services, pane, spare, keyPage)
        }
    }
}

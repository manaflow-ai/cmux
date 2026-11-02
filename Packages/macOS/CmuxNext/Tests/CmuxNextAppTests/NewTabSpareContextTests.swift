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
        try await PasswordManagerRouteTests.withApp { services, _ in
            services.agentTabs.localHost = AgentSessionRef.host(installID: "cn-spare-context")
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
            let workspace = try await services.windows.createWorkspace(WorkspaceSpawn(cwd: folder.path, name: "sf-spare"),
                                                                       into: controller.state.id)
            services.windows.show(workspaceID: workspace, in: controller.state)
            @MainActor func focused() -> PaneController? { controller.content?.focusedPane }
            // The page's folder (NewTabPageMachine: the selected terminal's, else the workspace's first tab's) is set
            // once the daemon's tab names it: the selected tab's own cwd can come later (fleet run 0b87f88f0040).
            @MainActor func keyCwd() -> String? {
                focused().flatMap { NewTabPage.page(services, selected: $0.selectedTab, window: window, pane: $0, paletteActions: false).cwd }
            }
            // The workspace's terminal pane gets the focus: a docked agent chat column can hold it (fleet run d87741821d15:
            // the focused pane showed a conversation, so the page had no folder).
            @MainActor func terminalPane() -> PaneController? {
                controller.content?.panes.values.first { pane in pane.selectedTab.map { "\($0.kind)" == "terminal" } ?? false }
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
            try await Task.sleep(for: NewTabSparePool.fitSettle * 3)
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

            // Cmd-T adopts it, and the screen it drew is the screen the tab gets: no remount after the key.
            let drawn = Self.screen(spare.model.newTab)
            NewTabPage.open(in: pane, seed: nil)
            #expect(pool.spare?.view !== spare, "Cmd-T did not adopt the parked spare")
            #expect(Self.screen(spare.model.newTab) == drawn, "the adoption changed the screen the spare drew before the key")
            #expect(!spare.model.newTabPrepared, "after Cmd-T the context is the tab's: its handshake may name its folder")
        }
    }
}

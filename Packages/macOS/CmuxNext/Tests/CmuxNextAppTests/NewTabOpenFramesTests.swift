import AppKit
@testable import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextTestSupport
import Foundation
import Testing

/// PACING TRIAGE #32910 (120 Hz films of Cmd-T, feat 585171513e37): each Cmd-T dropped 4-17 refreshes in the 50-150 ms
/// after the key, while two jobs of the open held the main thread: the pool made the next spare page (a web view and a
/// Chromium browser, then its setup calls and first load) in the key's own pass, and the bar's palette actions were read
/// in one 7-10 ms task 95 ms after the key. Neither is something the person sees in that open.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"),
                  .closesItsWindows)
struct NewTabOpenFramesTests {
    /// The pane Cmd-T opens in, once the window shows a workspace with a pane.
    static func focusedPane(_ services: AppServices) async throws -> (NSWindow, PaneController) {
        try await PasswordManagerRouteTests.until({ !services.windows.registry.isLaunching }, within: .seconds(60))
        let controller = try #require(services.windows.active)
        let window = try #require(controller.window)
        window.orderFrontRegardless()
        try await PasswordManagerRouteTests.until({ controller.content?.focusedPane != nil }, report: { "no focused pane" })
        return (window, try #require(controller.content?.focusedPane))
    }

    /// The next spare page is made once the open that took the parked one settled, never in the key's turn or the
    /// frames of its open.
    @Test func cmdTMakesTheNextSpareOnlyAfterItsOpenSettled() async throws {
        try await PasswordManagerRouteTests.withApp { services, _ in
            services.agentTabs.localHost = AgentSessionRef.host(installID: "cn-open-frames-spare")
            try #require(services.agentTabs.canHostChat, "this build has no New Tab page")
            let (window, pane) = try await Self.focusedPane(services)
            let folder = FileManager.default.temporaryDirectory.appending(path: "open-frames-\(UUID().uuidString.prefix(8))")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let html = folder.appending(path: "index.html")
            try Data("<html><body>New Tab spare fixture</body></html>".utf8).write(to: html)
            let pool = services.newTabSpares
            var made: [AgentPaneView] = []
            defer {
                pool.makeSpare = nil
                pool.dropAll()
                made.forEach { $0.close() }
                try? FileManager.default.removeItem(at: folder)
            }
            // An inert page stands in for WebKit's: the pool's own timing runs.
            pool.dropAll()
            pool.makeSpare = { page in
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
            let before = made.count

            NewTabPage.open(in: pane, seed: nil)
            #expect(pool.spare?.view !== spare, "Cmd-T did not adopt the parked spare")
            // The open's frames (60 ms: 7 refreshes at 120 Hz, the films' drops came 50-150 ms after the key).
            try await Task.sleep(for: .milliseconds(60))
            #expect(made.count == before, "the next spare was made in the open's frames (\(made.count - before) made within 60 ms)")
            // It still comes soon after, with no input, so the next Cmd-T finds a page loaded or loading.
            try await PasswordManagerRouteTests.until({ made.count == before + 1 }, within: .seconds(3),
                                                      report: { "no next spare after the open settled" })
        }
    }

    /// The bar's palette actions are read in slices on the main thread's budgeted work, never every action in one task:
    /// the bench spans (`newTab.paletteActions`, one per main-thread task that reads actions) show several short tasks.
    @Test func cmdTListsTheBarsPaletteActionsInSlices() async throws {
        try await PasswordManagerRouteTests.withApp { services, _ in
            services.agentTabs.localHost = AgentSessionRef.host(installID: "cn-open-frames-actions")
            try #require(services.agentTabs.canHostChat, "this build has no New Tab page")
            let (_, pane) = try await Self.focusedPane(services)
            let pool = services.newTabSpares
            pool.dropAll()
            pool.makeSpare = { _ in nil }
            defer { pool.makeSpare = nil }
            let pages = Set(services.agentTabs.newTabPages.keys)
            BenchSpans.begin()
            NewTabPage.open(in: pane, seed: nil)
            // The page's key is the tab's: a provisional one until the store answers, then the store's.
            @MainActor func actions() -> [AgentPaneOmnibar.Action] {
                let tabs = services.agentTabs
                guard let key = tabs.newTabPages.keys.first(where: { !pages.contains($0) }) else { return [] }
                return tabs.views[key]?.model.newTab?.omnibar.actions ?? tabs.newTabPages[key]?.page.omnibar.actions ?? []
            }
            try #require(services.agentTabs.newTabPages.keys.contains { !pages.contains($0) }, "Cmd-T opened no New Tab page")
            try await PasswordManagerRouteTests.until({ !actions().isEmpty }, report: { "the bar never got the palette's actions" })
            let reads = BenchSpans.end().filter { $0.name == "newTab.paletteActions" }
            // A listing takes one task to start and one to arrange; the reads between them are the slices.
            #expect(reads.count >= 4, "every palette action was read in one main-thread task (\(reads.map(\.milliseconds)) ms)")
        }
    }

    /// A page that joins the New Tab pages after the fill was asked for (Cmd-N's first page, `firstPage(cwd:token:)`)
    /// gets the palette's actions too.
    @Test func cmdNsFirstPageGetsThePalettesActions() async throws {
        try await PasswordManagerRouteTests.withApp { services, _ in
            services.agentTabs.localHost = AgentSessionRef.host(installID: "cn-open-frames-cmdn")
            try #require(services.agentTabs.canHostChat, "this build has no New Tab page")
            _ = try await Self.focusedPane(services)
            let tabs = services.agentTabs
            let made = try #require(tabs.firstPage(cwd: nil, token: nil), "no first page")
            let key = "open-frames-cmdn-\(UUID().uuidString.prefix(8))"
            tabs.newTabPages[key] = made
            defer { tabs.newTabPages[key] = nil }
            try await PasswordManagerRouteTests.until({ tabs.newTabPages[key]?.page.omnibar.actions.isEmpty == false },
                                                      report: { "Cmd-N's first page never got the palette's actions" })
        }
    }
}

import AppKit
import CmuxNextActions
import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextDaemon
import Foundation
import Testing

/// Perceived speed (2026-10-15): Cmd-T in a pane showing a lone New Tab page (its tab bar hidden)
/// adopted the prewarmed spare at the pane's one-tab size. The tab bar came in with the new tab,
/// so the page lost the bar's height in its first frame, and for 30-50 ms the pane showed it at the
/// old size: about 4 px low, its style dots cut off. The spare waits at the size the page shows at
/// once the tab is there, so the opening resizes nothing.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct NewTabSpareFinalSizeTests {
    @Test func cmdTOnALoneNewTabPageShowsTheSpareAtTheSizeItWaitedAt() async throws {
        try await PasswordManagerRouteTests.withApp { services, connection in
            services.agentTabs.localHost = AgentSessionRef.host(installID: "cn-spare-final-size")
            try #require(services.agentTabs.canHostChat, "this build has no New Tab page")
            let controller = try #require(services.windows.active)
            let window = try #require(controller.window)

            // A workspace holding one New Tab page, its tab bar hidden (a lone page is the chat it becomes).
            let created = try await connection.state.createWorkspace(name: "spare-final-size", ephemeral: false, terminal: false)
            try await PasswordManagerRouteTests.until { services.daemon.store.workspaces.contains { $0.resourceID == created.workspaceID } }
            let workspace = try #require(services.daemon.store.workspaces.first { $0.resourceID == created.workspaceID })
            services.windows.show(workspaceID: workspace.id, in: controller.state)
            try await PasswordManagerRouteTests.until({ controller.workspaceContent?.workspace.id == workspace.id && controller.focusedPane == nil })
            #expect(services.registry.perform("newTab.default", invocation: ActionInvocation(origin: .user)))
            try await PasswordManagerRouteTests.until({ controller.focusedPane?.currentTabKey.map(services.agentTabs.isNewTabPage) == true })
            let pane = try #require(controller.focusedPane)
            window.contentView?.layoutSubtreeIfNeeded()
            try await PasswordManagerRouteTests.until({ pane.view.hidesStrip }, report: { "the lone New Tab page shows its tab bar" })

            // The window's spare, warmed and parked for this pane.
            let pool = services.newTabSpares
            pool.start()
            pool.retarget(window)
            pool.prewarm()
            try await PasswordManagerRouteTests.until({ pool.spare != nil }, within: .seconds(30), report: { "no spare parked" })
            let spare = try #require(pool.spare?.view)
            // A pane resize or focus change settles before the parked spare follows it.
            try await Task.sleep(for: NewTabSparePool.fitSettle + .milliseconds(200))
            let waited = spare.frame.size

            // Cmd-T: the pane's second tab brings its tab bar, and the page shows under it.
            pane.newTabPage()
            try await PasswordManagerRouteTests.until({ !pane.view.hidesStrip }, within: .seconds(5), report: { "the second tab did not bring the tab bar" })
            window.contentView?.layoutSubtreeIfNeeded()
            guard case .agent(let shown)? = pane.currentContent else {
                Issue.record("the pane does not show the New Tab page")
                return
            }
            #expect(shown === spare, "the new tab did not adopt the spare")
            let final = pane.view.contentHost.bounds.size
            #expect(waited.height == final.height, "the spare waited \(waited.height) tall for a page shown \(final.height) tall")
            #expect(waited.width == final.width, "the spare waited \(waited.width) wide for a page shown \(final.width) wide")
            #expect(shown.frame.size == waited, "the opening resized the spare from \(waited) to \(shown.frame.size)")
        }
    }
}

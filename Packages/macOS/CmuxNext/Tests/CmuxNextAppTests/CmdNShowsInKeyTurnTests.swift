import AppKit
import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextDaemon
@testable import CmuxNextSidebar
import Foundation
import Testing

/// SWITCH STALL 4 and 6: Cmd-N's key changes the model in its turn, and its window shows the new workspace in that
/// turn's frame, before its Core Animation commit. SWITCH STALL 4: the window swapped its content one observation hop
/// later (`WindowController.observeWorkspace`), after the key's commit; when a display frame ran in between, it showed
/// the old workspace (about 95 ms to the new one under STRESS instead of 35-40; cmux22, macOS 27, 60 Hz, 2026-11-06).
/// SWITCH STALL 6: the swap then ran inside the key's handler, which put AppKit's hide and unhide walk of both workspace
/// trees, the layouts' liveness and the page's present (WindowController.show 5.3 of the 11.8 ms key turn, xctrace of
/// Release 67fff7fd on cmux22) in the key's turn. Chrome's model: the key changes the model in its turn; the view work
/// runs once in the frame that shows it. The frame here is one pass of the main run loop: its block phase runs before
/// AppKit's display cycle and the commit, and inside this main-queue job the pass runs no main-queue job (no
/// observation hop), so only work queued for the frame can show the workspace there. The same holds for the sidebar:
/// the key adds Cmd-N's row to the model in its turn, and the list draws it (one spliced row) in that frame.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct CmdNShowsInKeyTurnTests {
    /// One press: the workspace the window shows before the key, when the key's turn ends and after the turn's frame;
    /// the workspace the key made; the press's work.
    private struct Press {
        var before: String?, inKey: String?, inFrame: String?
        var made: String
        var work: [ActionWork]
        /// The sidebar's drawn rows before the key, when its turn ends and after its frame.
        var rowsBefore: Int, rowsInKey: Int, rowsInFrame: Int

        func expectSwapInFrame() {
            #expect(before != nil && inKey == before, "the key's turn swapped the window from \(before ?? "nothing") to \(inKey ?? "nothing"): view work belongs to the frame")
            #expect(inFrame == made, "the window showed \(inFrame ?? "nothing") in the key's frame, not Cmd-N's workspace \(made)")
            #expect(rowsInKey == rowsBefore, "the key's turn drew the sidebar (\(rowsBefore) to \(rowsInKey) rows): the row's redraw belongs to the frame")
            #expect(rowsInFrame == rowsBefore + 1, "the key's frame drew \(rowsInFrame) sidebar rows, not \(rowsBefore) and Cmd-N's row")
        }
    }

    private static func pressCmdN(_ services: AppServices) throws -> Press {
        let controller = try #require(services.windows.active, "no window")
        let store = services.daemon.store
        let before = Set(store.workspaces.map(\.id)), shownBefore = controller.content?.workspace.id
        let list = controller.sidebar.container.sidebarView.list, rowsBefore = list.displayed.rows.count
        var inKey: String?, rowsInKey = 0
        let work = services.registry.capturingWork {
            _ = services.registry.perform("newTab", invocation: ActionInvocation(origin: .user))
            inKey = controller.content?.workspace.id
            rowsInKey = list.displayed.rows.count
        }
        CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue) {} // the mode is never empty: the pass runs
        _ = CFRunLoopRunInMode(.defaultMode, 0, false)
        let made = try #require(store.workspaces.first { !before.contains($0.id) }?.id, "Cmd-N showed no workspace in its turn")
        return Press(before: shownBefore, inKey: inKey, inFrame: controller.content?.workspace.id, made: made, work: work,
                     rowsBefore: rowsBefore, rowsInKey: rowsInKey, rowsInFrame: list.displayed.rows.count)
    }

    /// The common press: the window built the next Cmd-N's view before the key (`reservedContent`).
    @Test func cmdNWithAReservedViewShowsItsWorkspaceInTheKeyFrame() async throws {
        try await PasswordManagerRouteTests.withApp { services, _ in
            services.agentTabs.localHost = AgentSessionRef.host(installID: "cn-cmdn-key-turn-reserved")
            try #require(services.agentTabs.canHostChat, "this build has no New Tab page")
            let controller = try #require(services.windows.active, "no window")
            controller.reservedContent.fill()
            try await PasswordManagerRouteTests.until({ controller.reservedContent.ready != nil && services.daemon.store.reservedWorkspace != nil },
                                                      within: .seconds(10), report: { "the window built no next Cmd-N view" })
            let press = try Self.pressCmdN(services)
            press.expectSwapInFrame()
            for task in press.work { _ = await task.value }
        }
    }

    /// A press with no view built before it (memory pressure let the reservation go, or the refill had not run).
    @Test func cmdNWithNoReservedViewShowsItsWorkspaceInTheKeyFrame() async throws {
        try await PasswordManagerRouteTests.withApp { services, _ in
            services.agentTabs.localHost = AgentSessionRef.host(installID: "cn-cmdn-key-turn-cold")
            try #require(services.agentTabs.canHostChat, "this build has no New Tab page")
            let controller = try #require(services.windows.active, "no window")
            controller.reservedContent.drop()
            services.agentTabs.releaseReservedWorkspace(on: services.daemon.store, .unshown)
            let press = try Self.pressCmdN(services)
            press.expectSwapInFrame()
            try await PasswordManagerRouteTests.until({ controller.content?.workspace.id == press.made && controller.content?.focusedPane != nil },
                                                      within: .seconds(2), report: { "the window shows no focused pane of Cmd-N's workspace" })
            for task in press.work { _ = await task.value }
        }
    }
}

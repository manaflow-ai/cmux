import AppKit
import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import Foundation
import Testing

/// SWITCH STALL 4: Cmd-N's window shows the new workspace in the key's own turn. The key's intent selected
/// the workspace in its window, but the window swapped its content one observation hop later
/// (`WindowController.observeWorkspace`), after the key's Core Animation commit. When a display frame ran in
/// between, it showed the old workspace and the swap, the page's child window and their commit came before
/// the next frame: about 95 ms to the new workspace under STRESS instead of 35-40 (cmux22, macOS 27, 60 Hz,
/// cmdn-latency runs 091a9785 and 99f2bd83, 2026-11-06). Chrome's model: the key changes the model and the
/// shown frame in the same turn.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct CmdNShowsInKeyTurnTests {
    /// The workspace the window shows when the key's turn ends, the workspace the key made, and the press's work.
    private static func pressCmdN(_ services: AppServices) throws -> (shown: String?, made: String, work: [ActionWork]) {
        let controller = try #require(services.windows.active, "no window")
        let store = services.daemon.store
        let before = Set(store.workspaces.map(\.id))
        var shown: String?
        let work = services.registry.capturingWork {
            _ = services.registry.perform("newTab", invocation: ActionInvocation(origin: .user))
            shown = controller.content?.workspace.id
        }
        let made = try #require(store.workspaces.first { !before.contains($0.id) }?.id, "Cmd-N showed no workspace in its turn")
        return (shown, made, work)
    }

    /// The common press: the window built the next Cmd-N's view before the key (`reservedContent`).
    @Test func cmdNWithAReservedViewShowsItsWorkspaceInTheKeyTurn() async throws {
        try await PasswordManagerRouteTests.withApp { services, _ in
            services.agentTabs.localHost = AgentSessionRef.host(installID: "cn-cmdn-key-turn-reserved")
            try #require(services.agentTabs.canHostChat, "this build has no New Tab page")
            let controller = try #require(services.windows.active, "no window")
            controller.reservedContent.fill()
            try await PasswordManagerRouteTests.until({ controller.reservedContent.ready != nil && services.daemon.store.reservedWorkspace != nil },
                                                      within: .seconds(10), report: { "the window built no next Cmd-N view" })
            let press = try Self.pressCmdN(services)
            #expect(press.shown == press.made, "the window still showed \(press.shown ?? "nothing") when Cmd-N's turn ended, not its workspace \(press.made)")
            for task in press.work { _ = await task.value }
        }
    }

    /// A press with no view built before it (memory pressure let the reservation go, or the refill had not run).
    @Test func cmdNWithNoReservedViewShowsItsWorkspaceInTheKeyTurn() async throws {
        try await PasswordManagerRouteTests.withApp { services, _ in
            services.agentTabs.localHost = AgentSessionRef.host(installID: "cn-cmdn-key-turn-cold")
            try #require(services.agentTabs.canHostChat, "this build has no New Tab page")
            let controller = try #require(services.windows.active, "no window")
            controller.reservedContent.drop()
            services.agentTabs.releaseReservedWorkspace(on: services.daemon.store, .unshown)
            let press = try Self.pressCmdN(services)
            #expect(press.shown == press.made, "the window still showed \(press.shown ?? "nothing") when Cmd-N's turn ended, not its workspace \(press.made)")
            try await PasswordManagerRouteTests.until({ controller.content?.workspace.id == press.made && controller.content?.focusedPane != nil },
                                                      within: .seconds(2), report: { "the window shows no focused pane of Cmd-N's workspace" })
            for task in press.work { _ = await task.value }
        }
    }
}

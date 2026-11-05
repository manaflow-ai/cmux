import AppKit
@testable import CmuxNextApp
import CmuxNextAgentPane
import CmuxNextAppCore
import CmuxNextDaemon
import Foundation
import Testing

/// Cmd-N's new workspace and its New Tab page show in the key's own turn (P4 instant create): when the create
/// returns to the key's handler, its window's content IS the new workspace. The store and the window's selection
/// had it in that turn, but the content swap waited for the window's observation hop (`observeWorkspace`), 8 to
/// 16 ms later: a display frame between the two still showed the old workspace, and when the stand-in's layout
/// then filled the next turns no frame came for about 100 ms (the 6-8 frame Cmd-N, CMD-N FIRST FRAME, STATUS 13669).
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct CmdNShowsInTheKeysTurnTests {
    @Test func theWindowShowsTheNewWorkspaceInTheKeysTurn() async throws {
        let launched = try await RapidWorkspaceCreateTests.launch()
        let services = launched.services
        let tabs = services.agentTabs
        tabs.localHost = tabs.localHost ?? AgentSessionRef.host(installID: "cmdn-keys-turn-test")
        tabs.holdsTabs = { _ in true }
        let canHost = tabs.canHostChat
        let controller = services.windows.active
        let shownBefore = controller?.content?.workspace.id
        let listedBefore = Set(services.daemon.store.workspaces.map(\.id))
        var create: (() async throws -> String)?
        if canHost, let window = controller?.state.id {
            create = services.windows.startWorkspace(WorkspaceSpawn(newTabPage: true), into: window)
        }
        // The key's turn: nothing has awaited the daemon or the window's observation yet.
        let standIn = services.daemon.store.workspaces.first { !listedBefore.contains($0.id) }?.id
        let selected = controller?.state.workspaceID
        let shown = controller?.content?.workspace.id
        let made = try? await create?()
        await launched.stop()

        try #require(canHost, "this build has no agent page")
        try #require(controller != nil, "no window")
        #expect(standIn != nil, "the key's turn listed no stand-in workspace")
        #expect(selected == standIn, "the window selected \(selected ?? "nil") in the key's turn, not the stand-in \(standIn ?? "nil")")
        #expect(shown == standIn && shown != shownBefore,
                "the window's content in the key's turn was \(shown ?? "nil") (before the key: \(shownBefore ?? "nil")), not the stand-in: it swapped only on its observation hop")
        #expect(made == standIn, "the daemon's create returned \(made ?? "nil")")
    }
}

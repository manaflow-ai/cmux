import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextAppCore
@testable import CmuxNextDaemon
import CmuxNextFocusUI
import Foundation
import Testing

/// A person types in a starting pane (a split the daemon has not answered), the daemon gives the
/// keys back, and the person closes the WORKSPACE or the SCREEN of that pane. The window then
/// shows another workspace or screen and its terminal gets the focus. The keys the closed pane gave
/// back must reach no terminal of the window: the person threw that pane away with what they typed
/// in it, and a held line with a Return would run in a terminal the person did not type it in.
///
/// Before the fix only a close of the tab or the pane dropped them (#41186): after Close Workspace
/// or a screen close the keys stayed held for the window for 3 s and went to the first terminal
/// that got the focus there.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct StartingPaneWorkspaceCloseTests {
    /// What the person closes.
    nonisolated enum Way: String, CaseIterable, Sendable {
        case closeWorkspace, closeScreen
    }

    /// Whether a close path told that it closes the workspace, and the keys that were still held for the window at that
    /// time (written and read on the main actor only).
    private nonisolated final class Told: @unchecked Sendable {
        var closing = false
        var stillHeld = Data()
    }

    @Test(arguments: Way.allCases)
    func aCloseOfWhatHoldsAStartingPaneDropsTheKeysItGaveBack(way: Way) async throws {
        let files = StartingPaneFixture.Files()
        defer { files.remove() }
        try await PinnedPageTests.withApp(bridge: files.bridge) { services, connection in
            let controller = try #require(services.windows.active)
            let content = try #require(controller.workspaceContent)
            let window = try #require(content.layoutView.window)
            let windowID = try #require(services.windows.owner(of: window)?.state.id)
            let closing = content.workspace
            let store = services.daemon.store
            let coordinator = services.keyRouter.creationInputCoordinator

            // The workspace the window shows after a workspace close.
            _ = try await connection.state.createWorkspace(name: "next-\(UUID().uuidString.prefix(6).lowercased())",
                                                           ephemeral: false, terminal: true, focus: false)
            try await PinnedPageTests.until({ store.workspaces.count >= 2 }, within: .seconds(30), report: { "\(store.workspaces.count) workspaces" })
            try #require(controller.workspaceContent === content, "the window left its first workspace")

            let starting = try await StartingPaneFixture.start(services: services, content: content, window: window, files: files)

            // The daemon gives the typed keys back while the pane still shows: no terminal can
            // take them yet, so they are held for the window.
            let told = Told()
            let before = WorkspaceClose.willClose
            WorkspaceClose.willClose = { workspace in
                // Close Workspace tells this when it SENDS the close. The window showed its next workspace earlier in the
                // same press (the row left and the selection moved), and a terminal that gets the focus there takes what
                // is held. So the keys must be gone before this point, not from it.
                if workspace === closing { GivenBackInput.shared.deliver(window: windowID, to: { told.stillHeld.append($0) }) }
                before?(workspace)
                if workspace === closing { told.closing = true }
            }
            defer { WorkspaceClose.willClose = before }
            let held = ContinuousClock.now
            coordinator.giveBack(Data("echo typed-in-the-starting-pane\r".utf8), terminal: starting.terminalID)

            switch way {
            case .closeWorkspace:
                // Close Workspace, as the CLI and MCP run it (nothing to ask).
                #expect(services.registry.perform("closeWorkspace", invocation: ActionInvocation(target: ActionTargetRef(kind: .workspace, id: closing.id), origin: .cli)),
                        "Close Workspace was refused")
                let went = await StartingPaneFixture.eventually(within: .milliseconds(2500)) { told.closing }
                try #require(went, "Close Workspace did not go ahead inside 2.5 s")
                #expect(told.stillHeld.isEmpty, "the keys were still held when Close Workspace sent its close, after the window showed the next workspace: \(String(decoding: told.stillHeld, as: UTF8.self))")
            case .closeScreen:
                // The one function every screen close runs (the screen's menu, the bar, the actions, a group's close).
                let screen = try #require(store.screen(containing: starting.standIn.pane.handle), "the starting pane is in no screen")
                ScreenCommands.close([screen], in: closing, daemon: services.daemon, services: services)
            }
            let waited = ContinuousClock.now - held

            var given = Data()
            GivenBackInput.shared.deliver(window: windowID, to: { given.append($0) })
            #expect(given.isEmpty, "\(way.rawValue): keys typed in the starting pane went to another terminal: \(String(decoding: given, as: UTF8.self))")
            #expect(waited < .milliseconds(2800), "the check ran \(waited) after the give-back: held keys leave by themselves after 3 s, so this run proves nothing")
            coordinator.giveBack(Data("echo given-back-after-the-close\r".utf8), terminal: starting.terminalID)
            GivenBackInput.shared.deliver(window: windowID, to: { given.append($0) })
            #expect(given.isEmpty, "\(way.rawValue): keys given back after the close went to another terminal: \(String(decoding: given, as: UTF8.self))")
        }
    }
}

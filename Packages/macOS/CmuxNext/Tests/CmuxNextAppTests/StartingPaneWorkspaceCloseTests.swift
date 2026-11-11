import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextAppCore
@testable import CmuxNextDaemon
import CmuxNextFocusUI
import Foundation
import Testing

/// A person types in a starting pane (a split the daemon has not answered), the daemon gives the
/// keys back, and the person closes the WORKSPACE of that pane. The window then shows the next
/// workspace and its terminal gets the focus. The keys the closed pane gave back must reach no
/// terminal of the window: the person threw that pane away with what they typed in it, and a
/// held line with a Return would run in a terminal of another workspace.
///
/// Before the fix Close Workspace dropped nothing: the keys stayed held for the window for 3 s
/// and went to the first terminal that got the focus there.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct StartingPaneWorkspaceCloseTests {
    /// Whether a close path told that it closes the workspace (written and read on the main actor only).
    private nonisolated final class Told: @unchecked Sendable {
        var closing = false
    }

    @Test func aWorkspaceCloseDropsTheKeysItsStartingPaneGaveBack() async throws {
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

            // The workspace the window shows after the close.
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
                before?(workspace)
                if workspace === closing { told.closing = true }
            }
            defer { WorkspaceClose.willClose = before }
            let held = ContinuousClock.now
            coordinator.giveBack(Data("echo typed-in-the-starting-pane\r".utf8), terminal: starting.terminalID)

            // Close Workspace, as the CLI and MCP run it (nothing to ask).
            #expect(services.registry.perform("closeWorkspace", invocation: ActionInvocation(target: ActionTargetRef(kind: .workspace, id: closing.id), origin: .cli)),
                    "Close Workspace was refused")
            let went = await StartingPaneFixture.eventually(within: .milliseconds(2500)) { told.closing }
            try #require(went, "Close Workspace did not go ahead inside 2.5 s")
            let waited = ContinuousClock.now - held

            var given = Data()
            GivenBackInput.shared.deliver(window: windowID, to: { given.append($0) })
            #expect(given.isEmpty, "keys typed in the starting pane of the closed workspace went to another terminal: \(String(decoding: given, as: UTF8.self))")
            #expect(waited < .milliseconds(2800), "the check ran \(waited) after the give-back: held keys leave by themselves after 3 s, so this run proves nothing")
            coordinator.giveBack(Data("echo given-back-after-the-close\r".utf8), terminal: starting.terminalID)
            GivenBackInput.shared.deliver(window: windowID, to: { given.append($0) })
            #expect(given.isEmpty, "keys given back after the workspace close went to another terminal: \(String(decoding: given, as: UTF8.self))")
        }
    }
}

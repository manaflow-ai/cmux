import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
import Foundation
import Testing

/// Open Folder in VS Code (Inline)… declares a workspace target (the sidebar row's menu): it
/// opens beside that workspace's pane, with that pane's folder (unimpl-audit-actions.md row 21).
@MainActor @Suite(.serialized, .timeLimit(.minutes(4)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct VSCodeInlineWorkspaceTargetTests {
    /// Open Folder in VS Code (Inline) on a right-clicked workspace acts beside that workspace's
    /// pane, not the focused one in another window.
    @Test func vsCodeInlineOnAWorkspaceTargetsThatWorkspacesPane() async throws {
        try await PinnedPageTests.withApp { services, _ in
            let other = services.windows.newWindow()
            try await PinnedPageTests.until({
                services.windows.controller(for: other)?.workspaceContent?.panes.isEmpty == false
            }, within: .seconds(60), report: { "windows \(services.windows.controllers.map(\.state.id))" })
            let active = try #require(services.windows.active)
            let elsewhere = try #require(services.windows.controllers.first { $0 !== active }, "one window only")
            let workspaceID = try #require(elsewhere.state.workspaceID)
            let pane = try VSCodeInlineHandlers.targetPane(ActionInvocation(target: ActionTargetRef(kind: .workspace, id: workspaceID)),
                                                           context: AppActionContext(services: services))
            #expect(pane.workspace === elsewhere.workspaceContent, "the folder opens beside the focused pane of another window")
        }
    }
}

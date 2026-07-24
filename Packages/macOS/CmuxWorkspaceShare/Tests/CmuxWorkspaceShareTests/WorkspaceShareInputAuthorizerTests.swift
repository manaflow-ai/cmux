import CmuxWorkspaceShare
import Foundation
import Testing

@Suite
struct WorkspaceShareInputAuthorizerTests {
    private let authorizer = WorkspaceShareInputAuthorizer()
    private let sharedWorkspaceID = UUID(uuidString: "B48857A2-D50B-4010-A3B7-CFC9358A1F2D")!
    private let unsharedWorkspaceID = UUID(uuidString: "D4837177-AB98-4F13-BD67-C9AB332B35FE")!
    private let currentTerminalPaneID = UUID(uuidString: "72C552A7-8F75-4DF3-AC47-3750D01D0C18")!
    private let stalePaneID = UUID(uuidString: "A8319FD0-0881-45E9-AB76-02D34D4BD1DE")!

    @Test
    func `Editor input reaches a current terminal pane in a shared workspace`() {
        #expect(
            authorizer.allowsTerminalInput(
                from: .editor,
                workspaceID: sharedWorkspaceID,
                paneID: currentTerminalPaneID,
                sharedWorkspaceIDs: [sharedWorkspaceID],
                currentTerminalPaneIDs: [currentTerminalPaneID]
            )
        )
    }

    @Test
    func `Viewer input is denied`() {
        #expect(
            !authorizer.allowsTerminalInput(
                from: .viewer,
                workspaceID: sharedWorkspaceID,
                paneID: currentTerminalPaneID,
                sharedWorkspaceIDs: [sharedWorkspaceID],
                currentTerminalPaneIDs: [currentTerminalPaneID]
            )
        )
    }

    @Test
    func `Input to an unshared workspace is denied`() {
        #expect(
            !authorizer.allowsTerminalInput(
                from: .editor,
                workspaceID: unsharedWorkspaceID,
                paneID: currentTerminalPaneID,
                sharedWorkspaceIDs: [sharedWorkspaceID],
                currentTerminalPaneIDs: [currentTerminalPaneID]
            )
        )
    }

    @Test
    func `Input to a stale or nonterminal pane is denied`() {
        #expect(
            !authorizer.allowsTerminalInput(
                from: .editor,
                workspaceID: sharedWorkspaceID,
                paneID: stalePaneID,
                sharedWorkspaceIDs: [sharedWorkspaceID],
                currentTerminalPaneIDs: [currentTerminalPaneID]
            )
        )
    }
}

#if os(iOS)
import CMUXMobileCore
import CmuxAgentChat
import CmuxMobileShell
import CmuxMobileShellModel
import SwiftUI
import Testing
@preconcurrency import UIKit
@testable import CmuxMobileShellUI

@MainActor
@Suite struct WorkspaceDetailViewChatPlaceholderTests {
    @Test func chatContentShowsAWaitingPlaceholderBeforeTheConversationStoreArrives() {
        let workspace = MobileWorkspacePreview(
            id: "workspace-1",
            name: "Workspace",
            terminals: []
        )
        let detail = WorkspaceDetailView(
            host: "Mac",
            connectionStatus: .connected,
            workspace: workspace,
            store: MobileShellComposite(workspaces: [workspace]),
            createWorkspace: {},
            canCreateWorkspace: false,
            createTerminal: {},
            renameWorkspace: nil,
            customizeWorkspace: nil,
            setWorkspaceUnread: nil,
            closeWorkspace: nil,
            reportTerminalViewport: { _, _, _ in },
            sendTerminalInput: { _ in },
            safeAreaContext: .fullWidth,
            backButtonConfiguration: nil,
            signOut: nil
        )
        let session = ChatSessionDescriptor(
            id: "session-1",
            agentKind: .claude,
            workspaceID: workspace.id.rawValue,
            terminalID: nil,
            state: .idle
        )

        let controller = UIHostingController(rootView: detail.chatContent(session))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.layoutIfNeeded()

        #expect(viewContainsAccessibilityIdentifier(controller.view, "WorkspaceChatPlaceholder"))
        window.isHidden = true
    }

    private func viewContainsAccessibilityIdentifier(
        _ view: UIView,
        _ identifier: String
    ) -> Bool {
        if view.accessibilityIdentifier == identifier {
            return true
        }
        return view.subviews.contains {
            viewContainsAccessibilityIdentifier($0, identifier)
        }
    }
}
#endif

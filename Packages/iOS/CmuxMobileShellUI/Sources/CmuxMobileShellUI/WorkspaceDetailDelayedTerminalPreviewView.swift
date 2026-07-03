import CmuxAgentChat
import CmuxMobileBrowser
import CmuxMobileShell
import CmuxMobileShellModel
import SwiftUI

#if os(iOS) && DEBUG
struct WorkspaceDetailDelayedTerminalPreviewView: View {
    private static let workspaceID = MobileWorkspacePreview.ID(rawValue: "workspace-delayed-terminal")
    private static let terminalID = MobileTerminalPreview.ID(rawValue: "terminal-delayed")
    private static let longWorkspaceTitle = "Extremely Long Workspace Title That Should Truncate Before Toolbar Buttons Overflow"
    private static let longTerminalTitle = "Long Agent Session Subtitle That Should Also Truncate First"
    /// The https://github.com/manaflow-ai/cmux/issues/7225 report shape: a short
    /// workspace name over a long agent-session tab name.
    private static let longSessionTerminalTitle = "✳ Iterate PR 6947 to green"

    @State private var store = MobileShellComposite(
        isSignedIn: true,
        connectionState: .connected,
        connectedHostName: "UI Test Mac",
        workspaces: [
            MobileWorkspacePreview(
                id: workspaceID,
                name: workspaceTitle,
                terminals: []
            ),
        ]
    )
    @State private var browserStore = BrowserSurfaceStore()
    @State private var didInjectTerminal = false

    var body: some View {
        WorkspaceShellView(
            store: store,
            signOut: {},
            showAddDevice: nil
        )
        .environment(browserStore)
        .task {
            guard !didInjectTerminal else { return }
            didInjectTerminal = true
            store.selectedWorkspaceID = Self.workspaceID
            try? await ContinuousClock().sleep(for: .milliseconds(1_500))
            guard !Task.isCancelled else { return }
            let workspace = MobileWorkspacePreview(
                id: Self.workspaceID,
                name: Self.workspaceTitle,
                terminals: [
                    MobileTerminalPreview(id: Self.terminalID, name: Self.terminalTitle),
                ]
            )
            store.replaceForegroundWorkspaceState([workspace])
            store.selectedWorkspaceID = Self.workspaceID
            store.selectedTerminalID = Self.terminalID
            if Self.showsChatToggle {
                store.rememberChatSessions(
                    [
                        ChatSessionDescriptor(
                            id: "preview-chat-session",
                            agentKind: .claude,
                            title: "Preview Agent",
                            workspaceID: Self.workspaceID.rawValue,
                            terminalID: Self.terminalID.rawValue,
                            state: .working(since: Date()),
                            lastActivityAt: Date()
                        ),
                    ],
                    workspaceID: Self.workspaceID.rawValue
                )
            }
        }
    }

    private static var usesLongTitle: Bool {
        ProcessInfo.processInfo.environment["CMUX_UITEST_WORKSPACE_DETAIL_LONG_TITLE"] == "1"
    }

    /// Short workspace name + long agent-session terminal name (issue #7225).
    private static var usesLongSessionTitle: Bool {
        ProcessInfo.processInfo.environment["CMUX_UITEST_WORKSPACE_DETAIL_LONG_SESSION_TITLE"] == "1"
    }

    private static var showsChatToggle: Bool {
        ProcessInfo.processInfo.environment["CMUX_UITEST_WORKSPACE_DETAIL_CHAT_TOGGLE"] == "1"
    }

    private static var workspaceTitle: String {
        if usesLongSessionTitle { return "cmux146" }
        return usesLongTitle ? longWorkspaceTitle : "New Workspace"
    }

    private static var terminalTitle: String {
        if usesLongSessionTitle { return longSessionTerminalTitle }
        return usesLongTitle ? longTerminalTitle : "Terminal 1"
    }
}
#endif

import CmuxAgentChat
import CmuxMobileBrowser
import CmuxMobileShell
import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

#if os(iOS) && DEBUG
struct WorkspaceDetailDelayedTerminalPreviewView: View {
    private static let workspaceID = MobileWorkspacePreview.ID(rawValue: "workspace-delayed-terminal")
    private static let terminalID = MobileTerminalPreview.ID(rawValue: "terminal-delayed")
    private static let longWorkspaceTitle = "Extremely Long Workspace Title That Should Truncate Before Toolbar Buttons Overflow"
    private static let longTerminalTitle = "Long Agent Session Subtitle That Should Also Truncate First"

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
                terminals: Self.injectedTerminals
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

    /// Number of terminals injected into the preview workspace, from
    /// `CMUX_UITEST_WORKSPACE_DETAIL_TERMINAL_COUNT` (default 1). A count above
    /// ~6 makes the terminal-picker toolbar menu tall enough to scroll, which is
    /// what the picker-scroll repro/regression captures need.
    private static var terminalCount: Int {
        let raw = ProcessInfo.processInfo.environment["CMUX_UITEST_WORKSPACE_DETAIL_TERMINAL_COUNT"]
        guard let raw, let count = Int(raw), count > 1 else { return 1 }
        return count
    }

    private static var injectedTerminals: [MobileTerminalPreview] {
        var terminals = [MobileTerminalPreview(id: terminalID, name: terminalTitle)]
        guard terminalCount > 1 else { return terminals }
        for index in 2...terminalCount {
            terminals.append(
                MobileTerminalPreview(
                    id: .init(rawValue: "\(terminalID.rawValue)-\(index)"),
                    name: L10n.terminalName(index: index)
                )
            )
        }
        return terminals
    }

    private static var showsChatToggle: Bool {
        ProcessInfo.processInfo.environment["CMUX_UITEST_WORKSPACE_DETAIL_CHAT_TOGGLE"] == "1"
    }

    private static var workspaceTitle: String {
        usesLongTitle ? longWorkspaceTitle : "New Workspace"
    }

    private static var terminalTitle: String {
        usesLongTitle ? longTerminalTitle : L10n.terminalName(index: 1)
    }
}
#endif

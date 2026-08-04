import CMUXMobileCore
import CmuxAgentChatUI
import SwiftUI

/// Labs title treatment that promotes the terminal name above the workspace.
struct WorkspaceTerminalFirstToolbarLabel: View {
    let token: WorkspaceTitleMenuLabelToken
    let terminalTheme: TerminalTheme

    @ViewBuilder
    var body: some View {
        switch token {
        case .chat(
            let descriptor,
            let agentState,
            let isConnected,
            let titleOverride,
            let subtitle
        ):
            ChatSessionHeaderView(
                descriptor: descriptor,
                agentState: agentState,
                isConnected: isConnected,
                titleOverride: titleOverride,
                subtitle: subtitle,
                style: .toolbarCompact
            )
        case .browser(let title):
            Text(title)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(terminalTheme.terminalChromeForegroundColor)
        case .standard(let workspaceTitle, let terminalTitle):
            WorkspaceToolbarTitleView(
                title: terminalTitle ?? workspaceTitle,
                subtitle: terminalTitle == nil ? nil : workspaceTitle
            )
        }
    }
}

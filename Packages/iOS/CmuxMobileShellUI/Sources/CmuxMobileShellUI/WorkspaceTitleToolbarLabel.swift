import CMUXMobileCore
import CmuxAgentChatUI
import SwiftUI

/// Shared workspace-detail title label for terminal, browser, and chat surfaces.
struct WorkspaceTitleToolbarLabel: View {
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
        case .standard(let title, let subtitle):
            WorkspaceToolbarTitleView(title: title, subtitle: subtitle)
        }
    }
}

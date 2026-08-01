import CMUXMobileCore
import CmuxAgentChatUI
import SwiftUI

/// Workspace-detail title content with the same quiet connection line used by
/// the workspace list. While degraded, the connection line temporarily takes
/// the subtitle row so the compact toolbar control never grows to three lines.
struct WorkspaceDetailTitleLabel: View {
    let labelToken: WorkspaceTitleMenuLabelToken
    let connectionStatusLine: WorkspaceConnectionStatusLine?
    let terminalTheme: TerminalTheme

    var body: some View {
        VStack(spacing: 1) {
            titleContent
            if let connectionStatusLine {
                WorkspaceConnectionStatusLineView(line: connectionStatusLine)
            }
        }
    }

    @ViewBuilder
    private var titleContent: some View {
        switch labelToken {
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
                subtitle: connectionStatusLine == nil ? subtitle : nil,
                style: .toolbarCompact
            )
        case .browser(let title):
            Text(title)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(terminalTheme.terminalChromeForegroundColor)
        case .standard(let title, let subtitle):
            WorkspaceToolbarTitleView(
                title: title,
                subtitle: connectionStatusLine == nil ? subtitle : nil
            )
        }
    }
}

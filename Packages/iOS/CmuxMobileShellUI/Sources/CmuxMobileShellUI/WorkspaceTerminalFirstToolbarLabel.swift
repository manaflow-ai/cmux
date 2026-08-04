#if os(iOS) && DEBUG
import CMUXMobileCore
import SwiftUI

/// Labs title treatment that promotes the terminal name above the workspace.
struct WorkspaceTerminalFirstToolbarLabel: View {
    let token: WorkspaceTitleMenuLabelToken
    let terminalTheme: TerminalTheme

    var body: some View {
        WorkspaceTitleToolbarLabel(
            token: terminalFirstToken,
            terminalTheme: terminalTheme
        )
    }

    private var terminalFirstToken: WorkspaceTitleMenuLabelToken {
        guard case .standard(let workspaceTitle, let terminalTitle) = token else {
            return token
        }
        return .standard(
            title: terminalTitle ?? workspaceTitle,
            subtitle: terminalTitle == nil ? nil : workspaceTitle
        )
    }
}
#endif

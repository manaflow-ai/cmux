import CMUXMobileCore
import CoreGraphics

struct WorkspaceTitleMenuValue: Equatable {
    let contentWidth: CGFloat
    let hasBackButton: Bool
    let hasTrailingCluster: Bool
    let hasChatToggle: Bool
    let isEnabled: Bool
    let workspaceName: String
    let hasUnread: Bool
    let canRenameWorkspace: Bool
    let canToggleReadState: Bool
    let canCloseWorkspace: Bool
    let labelToken: WorkspaceTitleMenuLabelToken
    let terminalTheme: TerminalTheme
}

import CMUXMobileCore
import CoreGraphics

struct WorkspaceTitleMenuValue: Equatable {
    let contentWidth: CGFloat
    let hasBackButton: Bool
    let hasTrailingCluster: Bool
    let measuredTrailingItemsWidth: CGFloat
    let measuredTrailingItemCount: Int
    let trailingItemCount: Int
    /// Collapse-recovery ratchet; see `MobileLeadingToolbarTitleWidth`.
    let hadTrailingCollapse: Bool
    let isEnabled: Bool
    let workspaceName: String
    let hasUnread: Bool
    let canCustomizeWorkspace: Bool
    let canRenameWorkspace: Bool
    let canToggleReadState: Bool
    let canCloseWorkspace: Bool
    let labelToken: WorkspaceTitleMenuLabelToken
    let terminalTheme: TerminalTheme
}

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
    /// Whether the menu offers Reconnect — the disconnected state's manual
    /// recovery entry now that no pill covers the terminal. Reauthentication
    /// keeps its own blocking banner instead.
    let canReconnect: Bool
    /// Whether the menu offers Browse Files: an SSH terminal is showing. The
    /// same command as the terminal's Files chip, so it stays reachable in
    /// the title (document) menu whatever the chip does.
    var canBrowseFiles = false
    let labelToken: WorkspaceTitleMenuLabelToken
    let terminalTheme: TerminalTheme
}

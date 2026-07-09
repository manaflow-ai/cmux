public import Foundation

/// The keyboard-focus intent the main window is currently honoring: either a
/// panel within a workspace owns focus, or the right sidebar owns focus in a
/// concrete ``RightSidebarMode``.
public enum MainWindowKeyboardFocusIntent: Equatable {
    /// A panel within `workspaceId` (identified by `panelId`) owns keyboard focus.
    case mainPanel(workspaceId: UUID, panelId: UUID)
    /// The right sidebar owns keyboard focus in `mode`.
    case rightSidebar(mode: RightSidebarMode)
}

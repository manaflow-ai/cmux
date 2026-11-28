import CmuxMobileShellModel
import CoreGraphics

struct WorkspaceMacTitlePickerValue: Equatable {
    let title: String
    let isLoading: Bool
    let selection: WorkspaceMacSelection
    let machines: [WorkspaceFilterMachine]
    let canAddDevice: Bool
    let labelWidth: CGFloat
    /// Captured by the toolbar host so a Menu's presentation environment cannot
    /// accidentally promote the compact iPhone label to the regular iPad style.
    var usesCompactLabelTreatment = true
    /// Mail-style connection status rendered under the title ("Reconnecting…"
    /// / "Not Connected"). `nil` while healthy or while other chrome owns the
    /// connection story.
    var statusLine: WorkspaceConnectionStatusLine?
    /// Draws the picker as a single ellipsis control. A phone's portrait split
    /// sidebar has room for one more icon in its leading group but not for a
    /// titled picker, which would push the whole group into the overflow menu.
    var usesIconLabel = false
}

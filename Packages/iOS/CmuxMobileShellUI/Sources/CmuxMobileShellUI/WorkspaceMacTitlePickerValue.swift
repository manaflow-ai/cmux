import CoreGraphics

struct WorkspaceMacTitlePickerValue: Equatable {
    let title: String
    let isLoading: Bool
    let selection: WorkspaceMacSelection
    let machines: [WorkspaceFilterMachine]
    let canAddDevice: Bool
    let labelWidth: CGFloat
    /// Mail-style connection status rendered under the title ("Reconnecting…"
    /// / "Not Connected"). `nil` while healthy or while other chrome owns the
    /// connection story.
    var statusLine: WorkspaceConnectionStatusLine?
}

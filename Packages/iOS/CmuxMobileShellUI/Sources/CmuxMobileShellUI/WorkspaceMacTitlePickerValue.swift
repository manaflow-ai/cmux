import CoreGraphics

struct WorkspaceMacTitlePickerValue: Equatable {
    let title: String
    let isLoading: Bool
    let selection: WorkspaceMacSelection
    let machines: [WorkspaceFilterMachine]
    /// Workspaces the All Computers row would show; `nil` renders no count.
    var allWorkspacesCount: Int? = nil
    let canAddDevice: Bool
    let labelWidth: CGFloat
}

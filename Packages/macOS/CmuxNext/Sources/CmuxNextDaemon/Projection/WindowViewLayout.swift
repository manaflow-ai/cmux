import Foundation

/// The workspaces a window shows side by side (`WindowRecord.multiView`, the app's Debug Settings
/// `sidebar.multiView`): a leaf names one workspace; a split lays its two `parts` out side by side or stacked,
/// half each. Opaque to the daemon, like the rest of the record.
public struct WindowViewLayout: Codable, Sendable, Hashable {
    public static let sideBySide = "row"
    public static let stacked = "column"

    /// A leaf: the workspace shown there.
    public var workspace: WorkspaceKey?
    /// A split: `row` (side by side) or `column` (stacked).
    public var axis: String?
    /// A split's two parts, left or top first.
    public var parts: [WindowViewLayout]?

    public init(workspace: WorkspaceKey? = nil, axis: String? = nil, parts: [WindowViewLayout]? = nil) {
        self.workspace = workspace
        self.axis = axis
        self.parts = parts
    }
}

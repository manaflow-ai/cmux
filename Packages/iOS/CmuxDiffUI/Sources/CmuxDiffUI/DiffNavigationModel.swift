/// The debug-selectable navigation shell for the native diff viewer.
public enum DiffNavigationModel: String, Sendable, Codable, CaseIterable, Hashable {
    /// Shows the changed-file tree before navigating to the continuous diff.
    case filesFirst
    /// Opens the continuous diff immediately and exposes the tree in a drawer.
    case diffFirst
}

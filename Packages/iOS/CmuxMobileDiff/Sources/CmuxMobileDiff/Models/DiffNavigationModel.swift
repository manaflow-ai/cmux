/// Selects the compact-width file-navigation composition for native diffs.
public enum DiffNavigationModel: String, CaseIterable, Equatable, Identifiable, Sendable {
    /// Opens a file tree first and pushes the continuous diff after selection.
    case filesFirst
    /// Opens the continuous diff with a pull-up file-tree drawer.
    case diffFirst

    /// Stable identity used by settings pickers and persistence.
    public var id: String { rawValue }
}

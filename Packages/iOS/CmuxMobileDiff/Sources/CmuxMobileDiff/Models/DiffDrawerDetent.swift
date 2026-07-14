/// Stable resting positions for the compact diff-first file drawer.
enum DiffDrawerDetent: CaseIterable, Sendable {
    /// Shows only the grab handle.
    case collapsed
    /// Shows roughly half of the available height.
    case half
    /// Shows nearly all of the available height.
    case full
}

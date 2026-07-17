/// Persisted preference that resolves native diff rows against device orientation.
public enum DiffLayoutPreference: String, CaseIterable, Equatable, Identifiable, Sendable {
    /// Uses unified rows in portrait and split rows in landscape.
    case automatic
    /// Always uses unified rows.
    case unified
    /// Always uses side-by-side old and new rows.
    case split

    /// Stable identity used by menus and persistence.
    public var id: String { rawValue }

    /// Resolves the preference to a concrete rendering mode.
    /// - Parameter isPhoneLandscape: Whether compact-width presentation is landscape.
    /// - Returns: The concrete unified or split mode.
    func resolved(isPhoneLandscape: Bool) -> DiffRenderingMode {
        switch self {
        case .automatic: isPhoneLandscape ? .split : .unified
        case .unified: .unified
        case .split: .split
        }
    }
}

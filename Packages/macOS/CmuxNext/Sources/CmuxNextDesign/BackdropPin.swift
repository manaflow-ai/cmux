public import CmuxNextAppearance

/// A scope's own background over its ancestors' (``ThemeScope/pinBackdrop(_:)``).
public nonisolated enum BackdropPin: Equatable, Sendable {
    /// Follow the ancestors (the app's `appearance.background`).
    case inherit
    /// Plain glass, even when an ancestor has art.
    case none
    case selection(BackdropSelection)
}

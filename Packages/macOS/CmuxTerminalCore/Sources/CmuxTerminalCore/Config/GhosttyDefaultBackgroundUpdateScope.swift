/// The precedence scope of a default-appearance (background/foreground/cursor)
/// update applied to the embedded ghostty runtime.
///
/// A higher-precedence update may overwrite the colors set by a lower- or
/// equal-precedence one, but a lower-precedence update is dropped while a
/// higher one is in effect. The raw values encode that precedence order
/// (`unscoped` < `app` < `surface`), so the decision is a pure comparison of two
/// scopes and owns no engine or window state. The app-target engine holds the
/// live ghostty handle and applies the result; the precedence decision lives
/// here beside the other appearance decisions (``GhosttyConfig`` plan/decision
/// helpers) so it can be unit-tested without a runtime.
public enum GhosttyDefaultBackgroundUpdateScope: Int, Sendable {
    /// No specific origin; the lowest precedence, overwritten by any scoped update.
    case unscoped = 0
    /// An app-wide appearance change (e.g. an OSC app color change).
    case app = 1
    /// A surface-specific appearance change; the highest precedence.
    case surface = 2

    /// A short stable label for logging.
    public var logLabel: String {
        switch self {
        case .unscoped: return "unscoped"
        case .app: return "app"
        case .surface: return "surface"
        }
    }

    /// Whether an update arriving at `self` (the incoming scope) should be
    /// applied over a default-appearance currently owned by `currentScope`.
    ///
    /// An update applies when its scope is at least as high-precedence as the
    /// current one; a strictly lower-precedence update is dropped.
    public func shouldApply(over currentScope: GhosttyDefaultBackgroundUpdateScope) -> Bool {
        rawValue >= currentScope.rawValue
    }
}

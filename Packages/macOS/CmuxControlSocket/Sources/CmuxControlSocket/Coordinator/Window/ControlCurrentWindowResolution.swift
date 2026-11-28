public import Foundation

/// The outcome of resolving the `window.current` target, preserving the two
/// distinct legacy failures: the routing selectors resolved no TabManager
/// (`unavailable`) versus a TabManager resolved but had no window id
/// (`not_found`).
public enum ControlCurrentWindowResolution: Sendable, Equatable {
    /// A window id resolved.
    case resolved(UUID)
    /// No TabManager resolved from the routing selectors (legacy
    /// `unavailable` / "TabManager not available").
    case tabManagerUnavailable
    /// A TabManager resolved but its window id could not be found (legacy
    /// `not_found` / "Current window not found").
    case windowNotFound
}

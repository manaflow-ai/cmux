import Foundation

/// The layout context a terminal is rendered in, used to decide safe-area handling.
public enum MobileTerminalSafeAreaContext: Equatable, Sendable {
    /// The terminal occupies the full width of the window.
    case fullWidth
    /// The terminal is shown alongside a visible split sidebar (e.g. on iPad).
    case splitSidebarVisible
}

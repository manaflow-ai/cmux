import Foundation

/// A decoded `right_sidebar` remote command, applied via
/// ``RightSidebarRemoteCommand/apply(target:host:strings:)``.
public enum RightSidebarRemoteCommand: Equatable, Sendable {
    /// Toggle the right sidebar visibility.
    case toggle
    /// Show the right sidebar (no-op if already visible).
    case show
    /// Hide the right sidebar.
    case hide
    /// Focus the right sidebar, preserving the current mode.
    case focus
    /// Select a mode, optionally moving keyboard focus into the sidebar.
    case setMode(RightSidebarMode, focus: Bool)
    /// Report the current visibility and mode without mutating state.
    case getState
}

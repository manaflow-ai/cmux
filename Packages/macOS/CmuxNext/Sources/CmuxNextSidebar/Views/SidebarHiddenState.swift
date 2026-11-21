import AppKit

/// Applies a visibility change only when the state actually changes.
///
/// AppKit's `isHidden` setter enters KVC and invalidates layout even when the
/// requested value is already in force. Sidebar layout runs for every window
/// resize and width-motion frame, so repeating those writes made a hot path
/// scale with frames instead of state changes.
@MainActor
enum SidebarHiddenState {
    /// Returns true when this call changed the view and entered AppKit's setter.
    @inline(__always)
    static func apply(_ hidden: Bool, to view: NSView) -> Bool {
        guard view.isHidden != hidden else { return false }
        view.isHidden = hidden
        return true
    }
}

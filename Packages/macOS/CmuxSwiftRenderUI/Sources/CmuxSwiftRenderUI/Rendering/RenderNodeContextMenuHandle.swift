import AppKit

/// Connects a row's SwiftUI `.accessibilityAction(.showMenu)` (the VoiceOver
/// path a native `.contextMenu` provides, VO-Shift-M) to the mounted overlay
/// view, so accessibility users keep interpreted context menus. Weak so the
/// handle never extends the platform view's lifetime.
@MainActor
final class RenderNodeContextMenuHandle {
    weak var view: RenderNodeContextMenuView?

    /// Presents the menu anchored to the overlay's row bounds (no mouse
    /// event exists on the accessibility path).
    func presentMenu() {
        view?.presentFromAccessibility()
    }
}

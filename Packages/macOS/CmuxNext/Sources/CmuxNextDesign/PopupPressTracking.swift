public import AppKit

/// A popup that one press both opens and chooses in, like a native menu.
///
/// A control that opens such a popup on mouse-down (``OverflowButton/pressPopup``)
/// keeps tracking the same press: each drag moves the popup's highlight, and the
/// release runs what is under the pointer. A release on nothing (the control
/// itself, outside the popup) leaves the popup open, so a plain click still
/// opens it (Lawrence 2026-10-21, u9795: "mousedown on the 3 dots, mousemove,
/// then mouseup to select what i want").
@MainActor
public protocol PopupPressTracking: AnyObject {
    /// The press moved to `point`: highlight what is under it, or nothing.
    ///
    /// - Parameter point: The pointer, in screen coordinates.
    func pressMoved(to point: CGPoint)

    /// The press ended at `point`: run what is under it; on nothing, stay open.
    ///
    /// - Parameter point: The pointer, in screen coordinates.
    func pressReleased(at point: CGPoint)
}

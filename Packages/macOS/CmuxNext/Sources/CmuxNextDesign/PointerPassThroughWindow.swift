public import AppKit

/// A window that draws only part of its frame and lets the pointer through the rest: hover over
/// what lies under its clear part belongs to the window below (``PointerHover``).
///
/// A hover card's window is its card plus a clear band for the shadow and the slide, and that band
/// reaches over what the card opened beside (the Updated card's x; Lawrence 2026-11-09: the x
/// "can't be hovered").
@MainActor
public protocol PointerPassThroughWindow: NSWindow {
    /// Whether `point` (screen coordinates) falls where this window draws nothing the pointer can use.
    ///
    /// - Parameter point: The pointer in screen coordinates.
    /// - Returns: True when hover at `point` belongs to the window below.
    func passesPointer(atScreen point: CGPoint) -> Bool
}

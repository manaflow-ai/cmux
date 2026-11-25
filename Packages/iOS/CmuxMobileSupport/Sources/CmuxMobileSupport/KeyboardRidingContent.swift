#if canImport(UIKit)
public import UIKit

/// A scroll view whose visible content is not its own scrolling: it says where
/// that content is drawn this frame. Read by the DEBUG keyboard probes
/// (`KeyboardPinTrace`'s `cb=`, the content settle bench).
///
/// The terminal is one: Ghostty draws its rows into a surface it places inside
/// the page's scroll view, and an idle shell's scroll view keeps one offset and
/// one content size through a keyboard toggle. Read from the scroll view alone,
/// the probe saw a content that never moved and the bench scored the terminal
/// as settled at the keyboard's will-change (-320 ms, a number it never measured).
@MainActor
public protocol KeyboardRidingContent: UIScrollView {
    /// The bottom edge of the last content drawn this frame (the terminal's
    /// last row, from presentation layers) in `window` coordinates; nil when
    /// nothing is drawn.
    func drawnContentBottom(in window: UIWindow) -> CGFloat?
}
#endif

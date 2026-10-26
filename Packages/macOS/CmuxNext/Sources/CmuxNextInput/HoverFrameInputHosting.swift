public import AppKit
public import CmuxNextWakeups

/// A window that carries the app's frame-aligned hover input (feature `pointerFrameHover`): a view that
/// hovers once per frame and has no owner to hand it the coalescers (a thin scroller, a hover reveal, a
/// hover card's moves) reads them from its window when it joins it, never on a move. The App's main
/// windows and their overlay panels carry them; any other window has none, and its views hover on every
/// move.
///
/// ```swift
/// override func viewDidMoveToWindow() {
///     super.viewDidMoveToWindow()
///     hover.frames = (window as? HoverFrameInputHosting)?.hoverFrameInput
/// }
/// ```
@MainActor
public protocol HoverFrameInputHosting: NSWindow {
    /// The windows' coalescers while the feature is on; nil while it is off.
    var hoverFrameInput: FrameInputCoalescers? { get }
}

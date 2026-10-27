public import AppKit

/// A window that carries the app's input tap: a view with no owner to hand it the tap (a find pill
/// that holds the tap's `findPillOpen` flag while its field edits) reads it from its window, never per
/// event. Every window that hosts the omnibar, a find pill or a sidebar carries it: the App's main
/// windows and the browser popup and sign-in windows. Any other window has none.
///
/// ```swift
/// let tap = (window as? InputTapHosting)?.inputTap
/// tap?.holdFlag(.findPillOpen)
/// ```
@MainActor
public protocol InputTapHosting: NSWindow {
    /// The app's one input tap.
    var inputTap: InputEventTap? { get }
}

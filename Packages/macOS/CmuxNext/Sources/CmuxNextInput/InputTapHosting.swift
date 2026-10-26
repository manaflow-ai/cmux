public import AppKit

/// A window that carries the app's input tap: a view with no owner to hand it the tap (a find pill
/// that holds the tap's `findPillOpen` flag while its field edits) reads it from its window, never per
/// event. The App's main windows carry it; any other window has none.
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

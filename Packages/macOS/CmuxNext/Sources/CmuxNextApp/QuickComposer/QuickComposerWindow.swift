import AppKit

/// The window `QuickComposerController` shows the chat in:
/// `QuickComposerPanel`, or a fake in tests.
protocol QuickComposerWindow: AnyObject {
    var isVisible: Bool { get }
    var isKeyWindow: Bool { get }
    /// The panel lost the keys (a click in another window or app).
    var onResignKey: (() -> Void)? { get set }
    /// Esc or Cmd-W that the page did not take.
    var onCancel: (() -> Void)? { get set }
    /// Shows `content` and gives `focus` the keys, without activating cmux.
    func present(_ content: NSView, focus: NSView?)
    /// Orders the panel out; `content` stays in it.
    func dismiss()
}

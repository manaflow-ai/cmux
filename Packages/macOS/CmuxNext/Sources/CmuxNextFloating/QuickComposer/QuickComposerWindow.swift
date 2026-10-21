public import AppKit

/// The window `QuickComposerController` shows the chat in:
/// `QuickComposerPanel`, or a fake in tests.
public protocol QuickComposerWindow: AnyObject {
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
    /// The floating chat (cx-b9qi): true once a started chat stays in the
    /// panel, false when it goes back to the compact composer.
    func holdChat(_ holds: Bool)
    /// The floating chat floats over other windows (true) or sits among them.
    func setOnTop(_ onTop: Bool)
    /// The floating chat folds to its compact bar (true) or opens again.
    func setCollapsed(_ collapsed: Bool)
}

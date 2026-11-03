public import AppKit

/// The sizing playground's window (`debug.sizingPlayground`, Debug menu > Sizing Playground, DEV and
/// NIGHTLY): ``show()`` opens ``SizingPlaygroundView`` in its own window, or raises it when open. The
/// App's action holds one; the window lives as long as it does.
@MainActor public final class SizingPlaygroundWindow {
    private var window: NSWindow?

    public init() {}

    /// Opens the playground window, or brings the open one to the front.
    public func show() {
        let window = window ?? SizingPlaygroundView.makeWindow()
        self.window = window
        window.makeKeyAndOrderFront(nil)
    }
}

public import AppKit

/// The tab bar playground's window (`debug.tabBarPlayground`, Debug menu > Tab Bar Playground, DEV
/// and NIGHTLY): ``show()`` opens ``TabBarPlaygroundView`` in its own window, or raises it when open.
/// The App's action holds one; the window lives as long as it does.
@MainActor public final class TabBarPlaygroundWindow {
    private var window: NSWindow?

    public init() {}

    /// Opens the playground window, or brings the open one to the front.
    public func show() {
        let window = window ?? TabBarPlaygroundView.makeWindow()
        self.window = window
        window.makeKeyAndOrderFront(nil)
    }
}

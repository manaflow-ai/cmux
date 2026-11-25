#if DEBUG || CMUX_BENCH_HOOKS
/// The window a `debug.key` key-down goes to when the request names no `target` (DEBUG builds).
///
/// A person's key goes to the key window. While a chat shown in Chromium has the keyboard (a menu
/// of its page is open, its composer is focused), that is the page's own window, a child of the
/// shell window, not the shell window. So a key with no `target` goes to the key window when it
/// is one of the shell's child windows. With no key window at all (a capture slot that never
/// activates), it goes to the focused agent chat's page window (`focusedPage`), where a person's key
/// would go; otherwise to the shell window (the shell itself, another window's child, no chat with
/// the keyboard). `"target": "shell"` always names the shell window. `Window` is any reference type,
/// so tests use plain objects:
///
/// ```swift
/// let route = DebugKeyRoute(shell: shell, keyWindow: NSApp.keyWindow, keyWindowParent: NSApp.keyWindow?.parent,
///                           focusedPage: agentFocused ? pageWindow(of: pane, in: controller) : nil)
/// let window = route.window(target: params["target"]?.stringValue)
/// ```
public struct DebugKeyRoute<Window: AnyObject> {
    /// The shell window of the window controller the request names (or the active one).
    public let shell: Window
    /// The app's key window, nil when the app has none.
    public let keyWindow: Window?
    /// The key window's parent window, nil when it is no child window.
    public let keyWindowParent: Window?
    /// The Chromium page window of the focused pane while its agent chat has the keyboard, else nil.
    public let focusedPage: Window?

    /// A route for one `debug.key` request.
    /// - Parameters:
    ///   - shell: The shell window the request names.
    ///   - keyWindow: The app's key window (`NSApp.keyWindow`).
    ///   - keyWindowParent: That window's `parent`.
    ///   - focusedPage: The focused agent chat's Chromium page window; nil (the default) for none.
    public init(shell: Window, keyWindow: Window?, keyWindowParent: Window?, focusedPage: Window? = nil) {
        self.shell = shell
        self.keyWindow = keyWindow
        self.keyWindowParent = keyWindowParent
        self.focusedPage = focusedPage
    }

    /// The window a key with `target` (nil: none named, or `"shell"`) goes to.
    /// - Parameter target: The request's `target`.
    /// - Returns: With no target: the key window when it is a child of the shell window, the focused chat's page
    ///   window when no window is key, else the shell window. With `"shell"`: the shell window.
    public func window(target: String?) -> Window {
        guard target == nil else { return shell }
        guard let keyWindow else { return focusedPage ?? shell }
        return keyWindow !== shell && keyWindowParent === shell ? keyWindow : shell
    }
}
#endif

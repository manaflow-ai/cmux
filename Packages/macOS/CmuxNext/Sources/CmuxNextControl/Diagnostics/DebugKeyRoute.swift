#if DEBUG || CMUX_BENCH_HOOKS
/// The window a `debug.key` key-down goes to when the request names no `target` (DEBUG builds).
///
/// A person's key goes to the key window. While a chat shown in Chromium has the keyboard (a menu
/// of its page is open, its composer is focused), that is the page's own window, a child of the
/// shell window, not the shell window. So a key with no `target` goes to the key window when it
/// is one of the shell's child windows, and to the shell window otherwise (no key window, as in a
/// capture slot that never activates; the shell itself; another window's child). `"target": "shell"`
/// always names the shell window. `Window` is any reference type, so tests use plain objects:
///
/// ```swift
/// let route = DebugKeyRoute(shell: shell, keyWindow: NSApp.keyWindow, keyWindowParent: NSApp.keyWindow?.parent)
/// let window = route.window(target: params["target"]?.stringValue)
/// ```
public struct DebugKeyRoute<Window: AnyObject> {
    /// The shell window of the window controller the request names (or the active one).
    public let shell: Window
    /// The app's key window, nil when the app has none.
    public let keyWindow: Window?
    /// The key window's parent window, nil when it is no child window.
    public let keyWindowParent: Window?

    /// A route for one `debug.key` request.
    /// - Parameters:
    ///   - shell: The shell window the request names.
    ///   - keyWindow: The app's key window (`NSApp.keyWindow`).
    ///   - keyWindowParent: That window's `parent`.
    public init(shell: Window, keyWindow: Window?, keyWindowParent: Window?) {
        self.shell = shell
        self.keyWindow = keyWindow
        self.keyWindowParent = keyWindowParent
    }

    /// The window a key with `target` (nil: none named, or `"shell"`) goes to.
    /// - Parameter target: The request's `target`.
    /// - Returns: The key window when no target is named and it is a child of the shell window, else the shell window.
    public func window(target: String?) -> Window {
        guard target == nil, let keyWindow, keyWindow !== shell, keyWindowParent === shell else { return shell }
        return keyWindow
    }
}
#endif

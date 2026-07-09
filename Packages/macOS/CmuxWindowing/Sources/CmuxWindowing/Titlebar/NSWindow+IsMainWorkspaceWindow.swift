public import AppKit

extension NSWindow {
    /// Whether this window is a main workspace window, identified solely by its
    /// `identifier` raw value: the primary window uses `"cmux.main"` and any
    /// secondary main-workspace window uses a `"cmux.main."` prefix.
    ///
    /// Pure `NSWindow.identifier` read, faithful lift of the app-side
    /// `isMainWorkspaceWindow(_:)` free function.
    public var isMainWorkspaceWindow: Bool {
        guard let raw = identifier?.rawValue else { return false }
        return raw == "cmux.main" || raw.hasPrefix("cmux.main.")
    }
}

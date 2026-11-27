import Foundation

/// Whether this Chromium can dock DevTools in the pane.
///
/// A docked DevTools is a Chromium child window over a view we own
/// (`CefWindowInfo::parent_view`). Forks before the embedded DevTools fix
/// (cef `f1d9ec948`, "embedded DevTools activation no longer recurses")
/// overflow the stack when that window activates, so they open DevTools in
/// its own window instead. The fix ships with fork API 4.
nonisolated enum CEFDevToolsSupport {
    static let embeddedMinimumForkAPI: Int32 = 4

    /// `CMUX_NEXT_CEF_EMBEDDED_DEVTOOLS=1` forces docking on for a local
    /// fork dist that has the fix at an older API version (Debug builds of
    /// development bundles only).
    static func allowsEmbedded(forkAPIVersion: Int32, bundleIdentifier: String?, environment: [String: String]) -> Bool {
        if forkAPIVersion >= embeddedMinimumForkAPI { return true }
        #if DEBUG
        let bundle = bundleIdentifier ?? ""
        return bundle.contains(".debug") && environment["CMUX_NEXT_CEF_EMBEDDED_DEVTOOLS"] == "1"
        #else
        return false
        #endif
    }
}

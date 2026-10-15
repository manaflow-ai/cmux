public import CoreGraphics

/// The CEF shim calls a page's DevTools, find, zoom and context menu features use.
///
/// ``CEFShimLibrary`` conforms; tests pass a recorder. Every call names the page's browser id.
@MainActor
public protocol CEFPageFeatureShim {
    /// The cmux Chromium fork's API version (embedded DevTools need 4 or later).
    var forkAPIVersion: Int32 { get }
    /// `cmux_shim_find`.
    func find(browser: Int32, text: String, forward: Bool, matchCase: Bool, findNext: Bool)
    /// `cmux_shim_stop_finding`.
    func stopFinding(browser: Int32, clearSelection: Bool)
    /// `cmux_shim_set_zoom_level` with a Chromium zoom level.
    func setZoomLevel(browser: Int32, level: Double)
    /// `cmux_shim_devtools_command`.
    func devToolsCommand(browser: Int32, command: Int32, x: Int32, y: Int32)
    /// `cmux_shim_devtools_set_placement`; a nil parent view means the engine's own window.
    func devToolsSetPlacement(browser: Int32, parentView: UnsafeMutableRawPointer?, frame: CGRect)
    /// `cmux_shim_devtools_set_focus`.
    func devToolsSetFocus(browser: Int32, focused: Bool)
    /// `cmux_shim_context_menu_done`; `commandID` -1 dismisses.
    func contextMenuDone(token: Int32, commandID: Int32)
}

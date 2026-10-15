public import CmuxCEF
public import CoreGraphics

/// Runs page feature calls through the loaded shim; every call is a no-op while CEF is not running.
@MainActor
public struct CEFShimPageFeatures: CEFPageFeatureShim {
    private let current: @MainActor () -> CEFShimLibrary?

    /// Creates the adapter over the runtime's shim.
    /// - Parameter library: The loaded shim, read at each call (`nil` before CEF started).
    public init(library: @escaping @MainActor () -> CEFShimLibrary?) {
        current = library
    }

    public var forkAPIVersion: Int32 { current()?.forkAPIVersion() ?? 0 }

    public func find(browser: Int32, text: String, forward: Bool, matchCase: Bool, findNext: Bool) {
        // CEF reports its own request identifier; the shim ignores this one.
        guard let library = current() else { return }
        text.withCString { library.find(browser, 0, $0, forward ? 1 : 0, matchCase ? 1 : 0, findNext ? 1 : 0) }
    }

    public func stopFinding(browser: Int32, clearSelection: Bool) {
        current()?.stopFinding(browser, clearSelection ? 1 : 0)
    }

    public func setZoomLevel(browser: Int32, level: Double) {
        current()?.setZoomLevel(browser, level)
    }

    public func devToolsCommand(browser: Int32, command: Int32, x: Int32, y: Int32) {
        _ = current()?.devToolsCommand(browser, command, x, y)
    }

    public func devToolsSetPlacement(browser: Int32, parentView: UnsafeMutableRawPointer?, frame: CGRect) {
        current()?.devToolsSetPlacement(
            browser, parentView,
            Int32(frame.minX.rounded()), Int32(frame.minY.rounded()),
            Int32(frame.width.rounded()), Int32(frame.height.rounded())
        )
    }

    public func devToolsSetFocus(browser: Int32, focused: Bool) {
        current()?.devToolsSetFocus(browser, focused ? 1 : 0)
    }

    public func contextMenuDone(token: Int32, commandID: Int32) {
        current()?.contextMenuDone(token, commandID, 0)
    }
}

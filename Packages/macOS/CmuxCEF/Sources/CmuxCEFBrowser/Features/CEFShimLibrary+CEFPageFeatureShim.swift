public import CmuxCEF
public import CoreGraphics

/// Runs page feature calls through the loaded shim.
@MainActor
public struct CEFShimPageFeatures: CEFPageFeatureShim {
    private let library: CEFShimLibrary

    /// Creates the adapter over the loaded shim.
    /// - Parameter library: The shim's resolved symbols.
    public init(library: CEFShimLibrary) {
        self.library = library
    }

    public var forkAPIVersion: Int32 { library.forkAPIVersion() }

    public func find(browser: Int32, text: String, forward: Bool, matchCase: Bool, findNext: Bool) {
        // CEF reports its own request identifier; the shim ignores this one.
        text.withCString { library.find(browser, 0, $0, forward ? 1 : 0, matchCase ? 1 : 0, findNext ? 1 : 0) }
    }

    public func stopFinding(browser: Int32, clearSelection: Bool) {
        library.stopFinding(browser, clearSelection ? 1 : 0)
    }

    public func setZoomLevel(browser: Int32, level: Double) {
        library.setZoomLevel(browser, level)
    }

    public func devToolsCommand(browser: Int32, command: Int32, x: Int32, y: Int32) {
        _ = library.devToolsCommand(browser, command, x, y)
    }

    public func devToolsSetPlacement(browser: Int32, parentView: UnsafeMutableRawPointer?, frame: CGRect) {
        library.devToolsSetPlacement(
            browser, parentView,
            Int32(frame.minX.rounded()), Int32(frame.minY.rounded()),
            Int32(frame.width.rounded()), Int32(frame.height.rounded())
        )
    }

    public func devToolsSetFocus(browser: Int32, focused: Bool) {
        library.devToolsSetFocus(browser, focused ? 1 : 0)
    }

    public func contextMenuDone(token: Int32, commandID: Int32) {
        library.contextMenuDone(token, commandID, 0)
    }
}

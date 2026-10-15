public import CmuxBrowser

/// Chromium's find-in-page for one browser: ``BrowserNativeFindSession`` drives it, and the page
/// forwards the shim's `findResult` events to the session.
@MainActor
public final class CEFNativeFindDriver: BrowserNativeFindDriving {
    private let shim: any CEFPageFeatureShim
    private let browserID: @MainActor () -> Int32?

    /// Creates a driver for one browser.
    /// - Parameters:
    ///   - shim: The shim calls.
    ///   - browserID: The page's browser id, `nil` before Chromium created it or after it closed.
    public init(shim: any CEFPageFeatureShim, browserID: @escaping @MainActor () -> Int32?) {
        self.shim = shim
        self.browserID = browserID
    }

    public func find(_ text: String, forward: Bool, matchCase: Bool, findNext: Bool) -> Bool {
        guard let id = browserID() else { return false }
        shim.find(browser: id, text: text, forward: forward, matchCase: matchCase, findNext: findNext)
        return true
    }

    public func stopFinding(clearSelection: Bool) {
        guard let id = browserID() else { return }
        shim.stopFinding(browser: id, clearSelection: clearSelection)
    }
}

public import CmuxBrowser

/// Chromium's find-in-page for one browser: ``BrowserNativeFindSession`` drives it, and the page
/// forwards the shim's `findResult` events to the session.
@MainActor
public final class CEFNativeFindDriver: BrowserNativeFindDriving {
    private let shim: any CEFPageFeatureShim
    private let browserID: Int32

    /// Creates a driver for one browser.
    /// - Parameters:
    ///   - shim: The shim calls.
    ///   - browserID: The page's browser id.
    public init(shim: any CEFPageFeatureShim, browserID: Int32) {
        self.shim = shim
        self.browserID = browserID
    }

    public func find(_ text: String, forward: Bool, matchCase: Bool, findNext: Bool) {
        shim.find(browser: browserID, text: text, forward: forward, matchCase: matchCase, findNext: findNext)
    }

    public func stopFinding(clearSelection: Bool) {
        shim.stopFinding(browser: browserID, clearSelection: clearSelection)
    }
}

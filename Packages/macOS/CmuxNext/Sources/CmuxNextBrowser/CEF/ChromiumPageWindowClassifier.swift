import AppKit

/// Whether a window is a Chromium page window (`CefNSWindow`: a page or its DevTools), with the class
/// looked up once CEF's framework registered it. The pump's input dispatches (``CEFPumpTapDispatches``)
/// and its board's focus check (``CEFPumpBoard``) share one. O(1), no allocation once the class is found.
final class ChromiumPageWindowClassifier {
    private let pageWindowClass: () -> AnyClass?
    private var pageClass: AnyClass?

    /// - Parameter pageWindowClass: Chromium's page window class, nil until it is registered (a test
    ///   passes its own subclass).
    init(pageWindowClass: @escaping () -> AnyClass? = ChromiumPageWindowMain.pageClass) {
        self.pageWindowClass = pageWindowClass
    }

    func isPage(_ window: NSWindow) -> Bool {
        if pageClass == nil { pageClass = pageWindowClass() }
        guard let pageClass else { return false }
        return window.isKind(of: pageClass)
    }
}

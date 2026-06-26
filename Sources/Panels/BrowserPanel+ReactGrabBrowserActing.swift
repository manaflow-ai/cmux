import CmuxBrowser

/// `BrowserPanel` already implements every React Grab toggle step (arming and
/// clearing the pasteback round-trip, requesting explicit web-view focus, and
/// the async ensure/inject/toggle). This declares the inversion conformance so
/// `ReactGrabController` (CmuxBrowser) can drive a toggle without the package
/// importing the app-target panel.
extension BrowserPanel: ReactGrabBrowserActing {}

import CmuxBrowser

/// `BrowserPanel` already implements every focused-browser command (page zoom,
/// browser focus mode, developer tools, the omnibar toggle). This declares the
/// inversion conformance so `FocusedBrowserController` (CmuxBrowser) can forward
/// to the focused panel without the package importing the app-target panel.
extension BrowserPanel: FocusedBrowserActing {}

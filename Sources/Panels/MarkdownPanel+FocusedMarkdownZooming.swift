import CmuxBrowser

/// `MarkdownPanel` already implements preview zoom in/out/reset. This declares
/// the inversion conformance so `FocusedBrowserController` (CmuxBrowser) can
/// zoom the focused markdown preview without the package importing the
/// app-target panel. The app-side resolver only hands over panels in preview
/// mode, matching the legacy `focusedMarkdownPanel` guard.
extension MarkdownPanel: FocusedMarkdownZooming {}

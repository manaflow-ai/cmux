public import CoreGraphics

/// A page shown in a child window above the panel's views (a Chromium page,
/// `BrowserPagePresentation.childWindow`) that can leave holes where native
/// UI must show over it.
///
/// The cmux Chromium fork reads the host view's `-cmuxOcclusionRects` on every
/// geometry update and masks the page window there, so the panel's own views
/// (find bar, permission bar, crash page) show through and get the mouse and
/// the keyboard as they do over a WebKit page. cef-embed's `CEFHostView` (or
/// the `CmuxCEFBrowser` page adapter wrapping it) conforms.
///
/// Reference: cmux Next `CmuxNextBrowser/Engine/BrowserTabHostingProtocols.swift`
/// (`BrowserOcclusionHosting`) and `CEF/CEFHostView.swift`.
@MainActor
public protocol BrowserPageOcclusionHosting: AnyObject {
    /// Rects in the page content view's own coordinate system (flipped or
    /// not, as the view is) where native UI covers the page. Setting an
    /// equal array must cost nothing.
    var pageOcclusionRects: [CGRect] { get set }
}

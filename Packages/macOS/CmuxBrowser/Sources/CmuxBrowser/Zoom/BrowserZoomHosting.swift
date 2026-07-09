public import CoreGraphics

/// The app-side seam ``BrowserZoomCoordinator`` drives for the one live page-zoom
/// effect it cannot own from the package. `BrowserPanel` conforms.
///
/// The coordinator owns the zoom decision (clamp into the policy bounds, the
/// per-step in/out arithmetic, and the fire-on-change epsilon check), but the
/// single live witness of the current zoom is the panel's `WKWebView.pageZoom`,
/// which never crosses the seam. The host exposes it as a read/write
/// ``livePageZoom`` so the coordinator can read the current factor to compute the
/// next one and write the clamped result back.
///
/// `@MainActor` because `WKWebView.pageZoom` is a main-actor AppKit/WebKit
/// property and the host (`BrowserPanel`) lives on main, so forwarding stays a
/// plain call with no bridging.
@MainActor
public protocol BrowserZoomHosting: AnyObject {
    /// The live page-zoom factor of the panel's web view (`webView.pageZoom`).
    /// Read to compute the next zoom factor and to run the fire-on-change check;
    /// written with the clamped result when it actually changes.
    var livePageZoom: CGFloat { get set }
}

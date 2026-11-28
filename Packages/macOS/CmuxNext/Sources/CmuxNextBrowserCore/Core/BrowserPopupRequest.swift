public import CoreGraphics
public import Foundation

/// A popup window a page asked for: `window.open` with window features
/// (OAuth and payment sign-in), an extension's
/// `chrome.windows.create({type: 'popup'})`. The host shows it in a small
/// floating panel over the opener's window, never as a separate Chromium
/// window; the page keeps `window.opener`.
public nonisolated struct BrowserPopupRequest: Hashable, Sendable {
    /// Content size the page asked for, in points. A zero width or height
    /// means the page gave none; the host picks it.
    public var size: CGSize
    /// Top-left of the content in screen points, measured from the top-left
    /// of the primary display, when the page gave a position.
    public var origin: CGPoint?

    public init(size: CGSize = .zero, origin: CGPoint? = nil) {
        self.size = size
        self.origin = origin
    }

    /// From window features (`x`, `y`, `width`, `height`; zero = not
    /// given), as engines report them.
    public init(features: CGRect?) {
        guard let features else {
            self.init()
            return
        }
        // The rule is Rust's (cmux-browser-rules `link_routes.rs`, over BrowserLinkRulesFFI).
        let rect: [String: Any] = ["x": Double(features.origin.x), "y": Double(features.origin.y), "width": Double(features.width), "height": Double(features.height)]
        guard features.origin.x.isFinite, features.origin.y.isFinite, features.width.isFinite, features.height.isFinite,
              let answer = BrowserLinkRulesFFI.call("popup_request", ["features": rect]) as? [String: Any],
              let width = (answer["width"] as? NSNumber)?.doubleValue, let height = (answer["height"] as? NSNumber)?.doubleValue else {
            self.init()
            return
        }
        let origin = (answer["x"] as? NSNumber).flatMap { x in (answer["y"] as? NSNumber).map { CGPoint(x: x.doubleValue, y: $0.doubleValue) } }
        self.init(size: CGSize(width: width, height: height), origin: origin)
    }
}

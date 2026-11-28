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
        let origin = features.origin == .zero ? nil : features.origin
        self.init(size: CGSize(width: max(features.width, 0), height: max(features.height, 0)), origin: origin)
    }
}

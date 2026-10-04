public import Foundation

/// The link destination a browser pane shows while the pointer is over a link.
public struct BrowserLinkHoverURL: Equatable, Sendable {
    /// The longest string handed to the indicator. A `data:` link can run to
    /// megabytes, and the indicator truncates to one line anyway.
    public static let maximumDisplayLength = 2_000

    /// The text to show in the pane's link hover indicator.
    public let displayString: String

    /// Creates the hover text for `url`, or `nil` when there is no link to show.
    public init?(url: URL?) {
        guard let absoluteString = url?.absoluteString, !absoluteString.isEmpty else { return nil }
        displayString = String(absoluteString.prefix(Self.maximumDisplayLength))
    }

    /// Creates the hover text from the hit-test result WebKit passes to
    /// `_webView:mouseDidMoveOverElement:withFlags:userInfo:`.
    ///
    /// The result is a private `_WKHitTestResult`, so its link is read by key
    /// and only when the object answers to it.
    public init?(hitTestResult: NSObject) {
        let key = "absoluteLinkURL"
        guard hitTestResult.responds(to: NSSelectorFromString(key)) else { return nil }
        self.init(url: hitTestResult.value(forKey: key) as? URL)
    }
}

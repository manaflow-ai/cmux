public import Foundation
import ObjectiveC
public import WebKit

/// The frames of a navigation, read so that a missing one is nil and never a trap.
///
/// WebKit declares `WKNavigationAction.sourceFrame` nonnull, but macOS 14's WebKit gives nil for
/// some navigations (a load the app starts in its own page). Read through its Swift type, the nil
/// frame answers a nil `request`, and bridging that to `URLRequest` traps
/// (`URLRequest._unconditionallyBridgeFromObjectiveC`: the cmux-next app ended at launch on macOS
/// 14.8.7 in `PageWebView.webView(_:decidePolicyFor:)`, Tart smoke 2026-11-05). An optional cast
/// (`sourceFrame as WKFrameInfo?`) is no fix: the optimizer may fold the nonnull value's `.some`.
/// These ask the Objective-C runtime for the getter, whose answer is typed optional, so nothing
/// here assumes nonnull. When the frame is there, the answer is the same object and URL as before.
public extension WKNavigationAction {
    /// The frame that asked for the navigation, or nil when WebKit gives none.
    var sourceFrameIfPresent: WKFrameInfo? {
        perform(#selector(getter: WKNavigationAction.sourceFrame))?.takeUnretainedValue() as? WKFrameInfo
    }

    /// The document of the frame that asked for the navigation, or nil.
    var sourceFrameURL: URL? { sourceFrameIfPresent?.requestURLIfPresent }

    /// The current document of the frame the navigation loads into, or nil (a new window, or none).
    var targetFrameURL: URL? { targetFrame?.requestURLIfPresent }
}

public extension WKFrameInfo {
    /// The frame's current request URL, or nil; `request` is declared nonnull and read the same way.
    var requestURLIfPresent: URL? {
        (perform(#selector(getter: WKFrameInfo.request))?.takeUnretainedValue() as? NSURLRequest)?.url
    }
}

public import Foundation

/// The event posted when a browser web view becomes first responder.
///
/// Carries the single `pointerInitiated` flag that distinguishes a focus change
/// driven by a pointer click from one driven by programmatic focus. The post
/// site (`CmuxWebView.becomeFirstResponder()`) and the observe site
/// (`AppDelegate.handleBrowserWebViewFirstResponderNotification(_:)`) stay
/// app-side; both encode/decode the bool payload through this type so the
/// `userInfo` key and notification name live in exactly one place.
///
/// Faithfully lifted from the app target's `BrowserFirstResponderNotificationUserInfoKey`
/// caseless namespace-enum plus the `Notification.Name.browserDidBecomeFirstResponderWebView`
/// declaration. The wire shape is unchanged: the notification name string is
/// `"browserDidBecomeFirstResponderWebView"` and the payload is a single
/// `userInfo` entry under the `"pointerInitiated"` key.
public struct BrowserFirstResponderEvent: Sendable, Equatable {
    /// The notification name posted by the web view and observed by the app
    /// delegate (and the layout/test-recorder observers).
    public static let notificationName = Notification.Name("browserDidBecomeFirstResponderWebView")

    /// The `userInfo` dictionary key carrying the pointer-initiated flag.
    private static let pointerInitiatedUserInfoKey = "pointerInitiated"

    /// `true` when the first-responder change was initiated by a pointer click
    /// (the posting web view had a positive pointer-focus-allowance depth).
    public var pointerInitiated: Bool

    /// Creates an event with an explicit pointer-initiated flag.
    public init(pointerInitiated: Bool) {
        self.pointerInitiated = pointerInitiated
    }

    /// Decodes the event from a posted notification's `userInfo`, defaulting the
    /// flag to `false` when the key is absent or not a `Bool` (matching the
    /// legacy `userInfo?[key] as? Bool ?? false` read).
    public init(userInfo: [AnyHashable: Any]?) {
        self.pointerInitiated = userInfo?[Self.pointerInitiatedUserInfoKey] as? Bool ?? false
    }

    /// The `userInfo` dictionary to attach when posting the notification.
    public var userInfo: [AnyHashable: Any] {
        [Self.pointerInitiatedUserInfoKey: pointerInitiated]
    }
}

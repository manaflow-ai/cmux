public import Foundation

/// The two short-lived focus-suppression deadlines a browser panel arms after
/// an explicit programmatic focus move, paired with the pure predicates that
/// decide whether suppression is still active.
///
/// Each suppression is a deadline: focus is suppressed while `Date()` is before
/// the stored `until` instant. The panel arms a deadline by storing
/// `Date().addingTimeInterval(seconds)`, clears it by storing `nil`, and asks
/// `isSuppressed(now:)` whether the window is still open. The value carries only
/// the two `Date?` deadlines so the panel can own it (or own the deadlines
/// directly) and read the decisions without an `NSView`, and a test can exercise
/// the comparison by passing a fixed `now`.
///
/// The web-view suppression also reacts to two app-side flags (an address-bar
/// suppression latch and whether a find/search session is open) that live on the
/// panel. Those are passed into `shouldSuppressWebViewFocus(addressBarSuppressed:searchActive:now:)`
/// as inputs rather than stored here, so only the deadline-comparison subset
/// lives in this value type.
public struct BrowserFocusSuppressionPolicy: Sendable, Equatable {
    /// The instant after which the omnibar may auto-focus again, or `nil` when
    /// omnibar auto-focus is not currently suppressed.
    ///
    /// Suppressing omnibar auto-focus for a short window after explicit
    /// programmatic focus avoids races where SwiftUI focus state steals first
    /// responder back from WebKit.
    public var omnibarAutofocusUntil: Date?

    /// The instant after which web-view focus may be forced again, or `nil` when
    /// the deadline-based web-view suppression is not currently armed.
    ///
    /// Suppressing forced web-view focus keeps omnibar text-field focus from
    /// being immediately stolen by panel focus when another UI path requested
    /// the omnibar.
    public var webViewFocusUntil: Date?

    /// Creates the policy from its two deadlines.
    /// - Parameters:
    ///   - omnibarAutofocusUntil: the omnibar auto-focus suppression deadline,
    ///     or `nil` when not suppressed.
    ///   - webViewFocusUntil: the web-view focus suppression deadline, or `nil`
    ///     when not armed.
    public init(omnibarAutofocusUntil: Date? = nil, webViewFocusUntil: Date? = nil) {
        self.omnibarAutofocusUntil = omnibarAutofocusUntil
        self.webViewFocusUntil = webViewFocusUntil
    }

    /// `true` when the omnibar auto-focus deadline is set and `now` is before it.
    /// - Parameter now: the instant to compare against the deadline.
    public func shouldSuppressOmnibarAutofocus(now: Date) -> Bool {
        if let until = omnibarAutofocusUntil {
            return now < until
        }
        return false
    }

    /// `true` when web-view focus should be suppressed.
    ///
    /// Web-view focus is suppressed while the address bar holds its suppression
    /// latch, while a find/search session is open, or while the deadline-based
    /// suppression window is still open.
    /// - Parameters:
    ///   - addressBarSuppressed: `true` while the address bar's web-view focus
    ///     suppression latch is held (app-side state).
    ///   - searchActive: `true` while a find/search session is open (app-side
    ///     state).
    ///   - now: the instant to compare against the deadline.
    public func shouldSuppressWebViewFocus(
        addressBarSuppressed: Bool,
        searchActive: Bool,
        now: Date
    ) -> Bool {
        if addressBarSuppressed {
            return true
        }
        if searchActive {
            return true
        }
        if let until = webViewFocusUntil {
            return now < until
        }
        return false
    }
}

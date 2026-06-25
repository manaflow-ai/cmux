import Foundation

/// Strongly-typed accessor for the `browserDidBecomeFirstResponderWebView`
/// notification's `userInfo` payload.
///
/// Replaces the former caseless `BrowserFirstResponderNotificationUserInfoKey`
/// namespace-enum (CONVENTIONS s5/s10 ban no-case-enum-as-namespace). The wire
/// key string `"pointerInitiated"` is kept private to this extension so the
/// payload shape stays identical; callers read/write the typed
/// `pointerInitiated` flag instead of stringly indexing `userInfo`.
extension Notification {
    /// The `userInfo` key carrying the pointer-initiated focus flag. Private so
    /// no call site reaches the raw string; both read and write go through the
    /// typed members below.
    private static let browserFirstResponderPointerInitiatedKey = "pointerInitiated"

    /// Whether the web-view first-responder acquisition was pointer-initiated.
    ///
    /// Reads the `browserDidBecomeFirstResponderWebView` payload; defaults to
    /// `false` when the flag is absent, matching the legacy
    /// `userInfo?[...] as? Bool ?? false` behavior exactly.
    var browserFirstResponderPointerInitiated: Bool {
        userInfo?[Self.browserFirstResponderPointerInitiatedKey] as? Bool ?? false
    }

    /// Builds the `userInfo` dictionary for a
    /// `browserDidBecomeFirstResponderWebView` post carrying the
    /// pointer-initiated flag.
    static func browserFirstResponderUserInfo(pointerInitiated: Bool) -> [AnyHashable: Any] {
        [browserFirstResponderPointerInitiatedKey: pointerInitiated]
    }
}

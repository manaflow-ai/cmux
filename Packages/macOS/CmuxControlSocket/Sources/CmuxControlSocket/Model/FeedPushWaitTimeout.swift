public import Foundation

/// The validated `wait_timeout_seconds` parameter of a `feed.push` control
/// command.
///
/// `feed.push` accepts an optional `wait_timeout_seconds` that bounds how long
/// the worker-lane handler blocks waiting for the feed item to resolve. The
/// legacy `TerminalController` parsed and bounds-checked this value in two
/// places with byte-identical rules (the id-less pre-dispatch validation and
/// the in-body `v2FeedPush` parse). This value type is the single source of
/// truth for that parse so the two call sites cannot drift.
///
/// The coercion mirrors the legacy `params["wait_timeout_seconds"]` reads
/// exactly: an `NSNumber` is read via `doubleValue` (so a JSON integer or
/// boolean coerces the same way the legacy `as? NSNumber` branch did), a Swift
/// `Double` or `Int` is accepted directly, and anything else is invalid. A
/// missing key means "do not wait" (`0`). The accepted range is the closed
/// interval `0...120`; `NaN`/infinite values are rejected.
public struct FeedPushWaitTimeout: Sendable, Equatable {
    /// The validated, non-negative, finite wait timeout in seconds, in `0...120`.
    public let seconds: TimeInterval

    /// Why a present `wait_timeout_seconds` value was rejected.
    ///
    /// The legacy `v2FeedPush` body emitted a distinct message for each reason,
    /// while the id-less pre-dispatch check combined them; exposing the reason
    /// lets both call sites stay byte-identical on the wire.
    public enum Rejection: Error, Sendable, Equatable {
        /// The value was present but not an `NSNumber`, `Double`, or `Int`.
        case nonNumeric
        /// The value was numeric but non-finite or outside `0...120`.
        case outOfRange
    }

    /// Parses the raw `wait_timeout_seconds` value, reporting the rejection
    /// reason on failure, exactly as the legacy `v2FeedPush` body did.
    ///
    /// - Parameter rawValue: The value stored at `params["wait_timeout_seconds"]`,
    ///   or `nil` when the key is absent (which yields a timeout of `0`).
    /// - Returns: `.success` with the validated timeout, or `.failure` with the
    ///   rejection reason.
    public static func parse(rawValue: Any?) -> Result<FeedPushWaitTimeout, Rejection> {
        guard let rawValue else {
            return .success(FeedPushWaitTimeout(unchecked: 0))
        }
        let parsed: Double?
        if let number = rawValue as? NSNumber {
            parsed = number.doubleValue
        } else if let value = rawValue as? Double {
            parsed = value
        } else if let value = rawValue as? Int {
            parsed = Double(value)
        } else {
            parsed = nil
        }
        guard let parsed else {
            return .failure(.nonNumeric)
        }
        guard parsed.isFinite, parsed >= 0, parsed <= 120 else {
            return .failure(.outOfRange)
        }
        return .success(FeedPushWaitTimeout(unchecked: parsed))
    }

    /// Parses the raw `wait_timeout_seconds` value exactly as the legacy id-less
    /// pre-dispatch check did, collapsing every rejection into `nil`.
    ///
    /// - Parameter rawValue: The value stored at `params["wait_timeout_seconds"]`,
    ///   or `nil` when the key is absent.
    /// - Returns: `nil` when the value is present but non-numeric, non-finite, or
    ///   outside `0...120`; otherwise the validated timeout (`0` when absent).
    public init?(rawValue: Any?) {
        switch FeedPushWaitTimeout.parse(rawValue: rawValue) {
        case .success(let timeout):
            self = timeout
        case .failure:
            return nil
        }
    }

    private init(unchecked seconds: TimeInterval) {
        self.seconds = seconds
    }
}

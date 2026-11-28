import Foundation

/// A single property value attached to an analytics event.
///
/// Analytics properties are deliberately restricted to a small set of JSON-safe
/// scalars so the emitter can serialize a batch without reflection and so the
/// privacy posture is obvious at the call site: only sizes, counts, flags, and
/// short enum strings ever flow through. The terminal text, paste contents,
/// search queries, host names, IPs, tickets, and tokens are *never* represented
/// here — by construction the catalog only ever passes counts and enums.
///
/// ```swift
/// let props: [String: AnalyticsValue] = [
///     "byte_count": .int(payload.utf8.count),
///     "method": .string("qr"),
///     "is_first_pair": .bool(true),
/// ]
/// ```
public enum AnalyticsValue: Sendable, Equatable {
    /// A string value, used for enum-style discriminators (never free text).
    case string(String)
    /// An integer value, used for counts, sizes, and durations in milliseconds.
    case int(Int)
    /// A floating-point value, used for fractional measurements.
    case double(Double)
    /// A boolean flag.
    case bool(Bool)

    /// The value rendered as a `Sendable` JSON-encodable object.
    ///
    /// Used by the emitter when assembling a batch payload for the capture
    /// endpoint. The returned values are all property-list/JSON safe.
    public var jsonObject: any Sendable {
        switch self {
        case let .string(value): return value
        case let .int(value): return value
        case let .double(value): return value
        case let .bool(value): return value
        }
    }
}

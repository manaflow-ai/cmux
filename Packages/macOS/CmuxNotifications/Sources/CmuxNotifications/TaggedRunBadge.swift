public import Foundation

/// A normalized run tag derived from the `CMUX_TAG` environment value, used to
/// prefix the dock badge for tagged dev builds.
///
/// Construction normalizes the raw tag exactly as the legacy
/// `TaggedRunBadgeSettings`: it trims surrounding whitespace and newlines,
/// rejects an empty result (returning `nil`), and clamps the length to the first
/// ``maxTagLength`` characters. Already-normalized input is a fixed point, so
/// re-wrapping a ``tag`` yields the same value.
public struct TaggedRunBadge: Sendable, Equatable {
    /// The environment variable carrying the run tag.
    public static let environmentKey = "CMUX_TAG"
    private static let maxTagLength = 10

    /// The normalized, non-empty tag string (at most ``maxTagLength`` characters).
    public let tag: String

    /// Normalizes `rawTag`, returning `nil` when it is missing or empty after trimming.
    public init?(_ rawTag: String?) {
        guard var tag = rawTag?.trimmingCharacters(in: .whitespacesAndNewlines), !tag.isEmpty else {
            return nil
        }
        if tag.count > Self.maxTagLength {
            tag = String(tag.prefix(Self.maxTagLength))
        }
        self.tag = tag
    }

    /// Normalizes the tag read from `environment[environmentKey]`, defaulting to the process environment.
    public init?(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.init(environment[Self.environmentKey])
    }
}

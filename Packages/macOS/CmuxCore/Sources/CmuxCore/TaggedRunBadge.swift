public import Foundation

/// Normalizes the `CMUX_TAG` run tag shown beside the Dock badge.
///
/// A pure value transform: it trims whitespace, drops an empty tag, and clamps
/// the length to ``maxTagLength``. The result feeds ``DockBadgeLabel`` as the
/// already-normalized tag. The environment key stays byte-identical to the
/// legacy `CMUX_TAG` lookup. `Sendable` because every member is a pure value
/// transform with no stored reference state.
public struct TaggedRunBadge: Sendable {
    /// The environment variable carrying the dev-build run tag.
    public static let environmentKey = "CMUX_TAG"
    /// The maximum number of characters retained from a run tag.
    public static let maxTagLength = 10

    /// The normalized tag, or `nil` when there is no usable tag.
    public let normalizedTag: String?

    /// Normalizes a raw tag string.
    public init(rawTag: String?) {
        guard var tag = rawTag?.trimmingCharacters(in: .whitespacesAndNewlines), !tag.isEmpty else {
            self.normalizedTag = nil
            return
        }
        if tag.count > Self.maxTagLength {
            tag = String(tag.prefix(Self.maxTagLength))
        }
        self.normalizedTag = tag
    }

    /// Normalizes the tag read from the given environment.
    public init(environment: [String: String]) {
        self.init(rawTag: environment[Self.environmentKey])
    }
}

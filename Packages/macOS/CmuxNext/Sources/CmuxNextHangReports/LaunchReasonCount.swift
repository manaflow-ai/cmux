/// How many launches completed for one ``LaunchCompletionReason``.
public nonisolated struct LaunchReasonCount: Codable, Sendable, Equatable {
    /// The reason.
    public var reason: LaunchCompletionReason
    /// How many launches completed for it.
    public var count: Int

    private enum CodingKeys: String, CodingKey {
        case reason, count
    }

    /// Makes the value from its parts, with the count clamped to `0...LaunchHistogram.maxCount`.
    public init(reason: LaunchCompletionReason, count: Int) {
        self.reason = reason
        self.count = min(max(0, count), LaunchHistogram.maxCount)
    }

    /// Decodes through ``init(reason:count:)``, so a saved file is clamped too.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(reason: try container.decode(LaunchCompletionReason.self, forKey: .reason),
                  count: try container.decode(Int.self, forKey: .count))
    }

    /// `counts` merged by reason, in ``LaunchCompletionReason`` order, zero counts left out.
    public static func merged(_ counts: [LaunchReasonCount]) -> [LaunchReasonCount] {
        LaunchCompletionReason.allCases.compactMap { reason in
            let total = counts.filter { $0.reason == reason }.reduce(0) { min($0 + $1.count, LaunchHistogram.maxCount) }
            return total > 0 ? LaunchReasonCount(reason: reason, count: total) : nil
        }
    }
}

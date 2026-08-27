import Foundation

/// Bounds the amount of Codex history a verification batch may inspect.
///
/// A hook store can contain a long-lived history of child and review records.
/// These limits keep restore-index reconciliation finite while allowing the
/// caller to distinguish an omitted read (`unavailable`) from a verified miss.
public struct CodexSessionResumeVerificationLimits: Sendable {
    /// Maximum number of identities admitted to one verification batch.
    public static let maximumBatchRequests = 512
    /// Maximum aggregate rollout bytes admitted to one verification budget.
    public static let maximumBatchBytes = 64 * 1024 * 1024
    /// Maximum bytes read from any one rollout.
    public static let maximumRolloutBytes = 8 * 1024 * 1024
    /// Maximum leading JSONL lines inspected in any one rollout.
    public static let maximumRolloutLines = 32

    /// Remaining aggregate rollout bytes in this budget.
    public private(set) var remainingBytes: Int

    /// Creates a verification budget.
    ///
    /// - Parameter maximumBytes: Aggregate rollout bytes allowed before
    ///   subsequent reads become unavailable.
    public init(maximumBytes: Int = Self.maximumBatchBytes) {
        remainingBytes = max(0, maximumBytes)
    }

    /// Whether another bounded rollout read can be attempted.
    public var hasRemainingBytes: Bool {
        remainingBytes > 0
    }

    /// Reserves a conservative per-file allowance from the aggregate budget.
    mutating func allowance(
        for path: String,
        fileManager: FileManager,
        maximumFileBytes: Int = Self.maximumRolloutBytes
    ) -> Int? {
        guard remainingBytes > 0,
              let attributes = try? fileManager.attributesOfItem(atPath: path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber,
              size.int64Value > 0 else {
            return nil
        }
        let fileSize = min(Int64(maximumFileBytes), size.int64Value)
        let allowed = min(Int64(remainingBytes), fileSize)
        guard allowed > 0 else { return nil }
        remainingBytes -= Int(allowed)
        return Int(allowed)
    }
}

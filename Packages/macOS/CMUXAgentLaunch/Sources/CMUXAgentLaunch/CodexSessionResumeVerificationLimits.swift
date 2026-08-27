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

    /// Returns the maximum number of bytes this file may read from the budget.
    ///
    /// The budget is charged as bytes actually arrive from the file handle, not
    /// by the file's advertised size. A large rollout normally exposes its
    /// `session_meta` record near the beginning, so charging the whole 8 MiB
    /// ceiling would needlessly starve later identities in the same batch.
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
        let allowed = min(Int64(remainingBytes), Int64(maximumFileBytes))
        guard allowed > 0 else { return nil }
        return Int(allowed)
    }

    /// Charges bytes actually consumed by a bounded rollout read.
    mutating func consume(_ byteCount: Int) {
        guard byteCount > 0 else { return }
        remainingBytes = max(0, remainingBytes - byteCount)
    }
}

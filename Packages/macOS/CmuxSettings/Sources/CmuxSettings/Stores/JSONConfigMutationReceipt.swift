import Foundation

/// An in-memory receipt for one persisted path, used for conditional undo.
///
/// Absence (`nil`) is distinct from an explicit default or JSON `null`.
/// Receipts hold config values: keep them local and do not log them. A receipt
/// records disk persistence only; it makes no claim that a runtime consumer
/// observed or applied the change.
public struct JSONConfigMutationReceipt: Sendable {
    /// The owned dotted path.
    public let path: String
    /// Canonical JSON before the mutation, or `nil` when the path was absent.
    public let before: Data?
    /// Canonical JSON the mutation installed, or `nil` for a reset.
    public let installed: Data?
    /// The resolved file the mutation published to.
    let target: URL

    static func encode(_ value: Any?) throws -> Data? {
        guard let value else { return nil }
        return try JSONSerialization.data(
            withJSONObject: canonicalJSONObject(value),
            options: [.fragmentsAllowed, .sortedKeys]
        )
    }
}

/// Re-encodes numbers the way ``CmuxSettingValue`` writes them, so `1.4`
/// read back from disk and `1.4` about to be written compare equal. Without
/// it, `JSONSerialization` prints the parsed double as `1.3999999999999999`
/// and every re-set of a fraction looks like a change.
func canonicalJSONObject(_ value: Any) -> Any {
    CmuxSettingValue(jsonObject: value)?.jsonObject ?? value
}

import Foundation

/// An in-memory receipt for one persisted path, suitable for conditional undo.
///
/// Absence is distinct from an explicit default, null, or override. Receipts
/// contain config values: keep them local, do not log them. They make no claim
/// that a runtime consumer observed or applied the persisted change.
public struct JSONConfigMutationReceipt: Sendable {
    /// The owned dotted path.
    public let path: String
    /// JSON before the mutation, or nil for an inherited/unset value.
    public let before: Data?
    /// JSON installed by the mutation, or nil for reset.
    public let installed: Data?
    let target: URL

    static func encode(_ value: Any?) throws -> Data? {
        guard let value else { return nil }
        return try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys])
    }
}

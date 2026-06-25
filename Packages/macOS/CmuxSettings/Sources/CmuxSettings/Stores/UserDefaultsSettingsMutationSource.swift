import Foundation

/// Identifies one caller-originated `UserDefaultsSettingsStore` mutation.
///
/// Consumers that optimistically update UI can attach a source to their store
/// write and ignore the matching observation echo without suppressing unrelated
/// external writes that happen to carry the same setting value.
public struct UserDefaultsSettingsMutationSource: Sendable, Hashable {
    /// Stable identity for the caller that originated the mutation.
    public let ownerID: UUID

    /// Monotonically increasing sequence number within ``ownerID``.
    public let sequence: UInt64

    /// Creates a unique mutation source for one logical write.
    public init() {
        self.init(ownerID: UUID(), sequence: 0)
    }

    /// Creates a mutation source scoped to an owner-local sequence.
    ///
    /// - Parameters:
    ///   - ownerID: Stable identity for the caller that originated the write.
    ///   - sequence: Monotonically increasing sequence number for `ownerID`.
    public init(ownerID: UUID, sequence: UInt64) {
        self.ownerID = ownerID
        self.sequence = sequence
    }
}

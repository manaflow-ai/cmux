import Foundation
import Dispatch
import os

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

    /// Monotonic creation-time order for this logical mutation.
    ///
    /// This lets the store reject an older delayed write after a later write from
    /// another source owner has already committed.
    let logicalOrder: UInt64

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
        self.init(
            ownerID: ownerID,
            sequence: sequence,
            logicalOrder: Self.nextLogicalOrder()
        )
    }

    /// Creates a mutation source with an explicit logical order.
    ///
    /// - Parameters:
    ///   - ownerID: Stable identity for the caller that originated the write.
    ///   - sequence: Monotonically increasing sequence number for `ownerID`.
    ///   - logicalOrder: Monotonic creation-time order for the logical write.
    init(ownerID: UUID, sequence: UInt64, logicalOrder: UInt64) {
        self.ownerID = ownerID
        self.sequence = sequence
        self.logicalOrder = logicalOrder
    }

    /// Returns whether two mutation sources identify the same logical write.
    public static func == (
        lhs: UserDefaultsSettingsMutationSource,
        rhs: UserDefaultsSettingsMutationSource
    ) -> Bool {
        lhs.ownerID == rhs.ownerID && lhs.sequence == rhs.sequence
    }

    /// Hashes the source identity while excluding ordering metadata.
    public func hash(into hasher: inout Hasher) {
        hasher.combine(ownerID)
        hasher.combine(sequence)
    }

    static func nextLogicalOrder() -> UInt64 {
        logicalOrderState.withLock { lastOrder in
            let clockOrder = DispatchTime.now().uptimeNanoseconds
            let nextOrder = if clockOrder > lastOrder {
                clockOrder
            } else if lastOrder == UInt64.max {
                UInt64.max
            } else {
                lastOrder + 1
            }
            lastOrder = nextOrder
            return nextOrder
        }
    }

    // Justification: synchronous source creation needs a process-local logical
    // clock; this lock only guards one counter and avoids forcing an async
    // factory into SwiftUI `Binding` setters.
    private nonisolated static let logicalOrderState = OSAllocatedUnfairLock(initialState: UInt64(0))
}

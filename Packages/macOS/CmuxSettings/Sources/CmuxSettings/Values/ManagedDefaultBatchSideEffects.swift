import Foundation

/// A batch of `ManagedDefaultSideEffect` descriptors accumulated across a
/// managed-defaults apply, deduped per `defaultsKey` so the latest change for a
/// key wins.
///
/// `append` removes any earlier entry for the same key before adding the new
/// one, so replaying the batch fires each key's downstream notification and
/// applier exactly once with the most recent source/synchronize context.
/// `merge` folds another batch in through the same dedup-on-append path.
public struct ManagedDefaultBatchSideEffects: Sendable {
    /// The accumulated changes, in append order, at most one entry per
    /// `defaultsKey`.
    public private(set) var changes: [ManagedDefaultSideEffect] = []

    /// Creates an empty batch.
    public init() {}

    /// Whether the batch holds no changes.
    public var isEmpty: Bool {
        changes.isEmpty
    }

    /// Folds another batch into this one, re-appending each change so the
    /// per-key dedup-on-append rule applies across the merge.
    public mutating func merge(_ other: ManagedDefaultBatchSideEffects) {
        for change in other.changes {
            append(
                defaultsKey: change.defaultsKey,
                source: change.source,
                synchronizeAppearanceTerminalTheme: change.synchronizeAppearanceTerminalTheme
            )
        }
    }

    /// Records a managed-default change, dropping any prior entry for the same
    /// `defaultsKey` so the latest change wins.
    public mutating func append(
        defaultsKey: String,
        source: String,
        synchronizeAppearanceTerminalTheme: Bool
    ) {
        changes.removeAll { $0.defaultsKey == defaultsKey }
        changes.append(
            ManagedDefaultSideEffect(
                defaultsKey: defaultsKey,
                source: source,
                synchronizeAppearanceTerminalTheme: synchronizeAppearanceTerminalTheme
            )
        )
    }
}

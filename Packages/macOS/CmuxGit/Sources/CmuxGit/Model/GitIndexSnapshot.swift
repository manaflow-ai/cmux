import Foundation

/// The result of parsing a git `index` file: the tracked entries plus two
/// signatures used to detect change.
///
/// Used internally by ``GitMetadataService``; surfaced for test inspection.
struct GitIndexSnapshot: Sendable {
    /// The tracked entries that participate in dirty-detection (assume-unchanged
    /// and skip-worktree entries are excluded).
    let entries: [GitIndexEntryStat]

    /// The raw index trailing-checksum signature (changes on any index rewrite).
    let signature: String

    /// A content signature over all entries' paths, modes, and object IDs that
    /// is stable across index rewrites which don't change tracked content.
    let contentSignature: String
}

import SwiftUI

/// The quiet capsule badge a file row shows for exceptional change kinds.
///
/// Most rows are plain modifications and show no badge at all: the +/− counts
/// and mini-bar already carry the magnitude, so the list stays calm. Only the
/// states a reviewer treats differently are called out, in words rather than a
/// symbol zoo: brand-new files ("New", covering added and untracked alike) and
/// deletions ("Deleted"). Renames are not badged because the row's
/// "old → new" path already says it.
public struct FileChangeBadge: Equatable, Sendable {
    /// The badge's semantic tint family.
    public enum Role: Equatable, Sendable {
        /// The file did not exist at the comparison base.
        case new
        /// The file no longer exists in the working tree.
        case deleted
    }

    /// Localized badge text.
    public let text: String
    /// Tint family resolved against ``ChangesTheme``.
    public let role: Role
}

/// Display metadata derived from a file-change category.
extension FileChangeKind {
    /// The capsule badge for this kind, or `nil` for ordinary modifications
    /// and renames.
    public var badge: FileChangeBadge? {
        switch self {
        case .added, .untracked:
            FileChangeBadge(
                text: String(localized: "changes.badge.new", defaultValue: "New", bundle: .module),
                role: .new
            )
        case .deleted:
            FileChangeBadge(
                text: String(localized: "changes.badge.deleted", defaultValue: "Deleted", bundle: .module),
                role: .deleted
            )
        case .modified, .renamed, .unknown:
            nil
        }
    }

    /// Localized spoken status for accessibility.
    public var localizedDisplayName: String {
        switch self {
        case .added:
            String(localized: "changes.status.added", defaultValue: "added", bundle: .module)
        case .modified:
            String(localized: "changes.status.modified", defaultValue: "modified", bundle: .module)
        case .deleted:
            String(localized: "changes.status.deleted", defaultValue: "deleted", bundle: .module)
        case .renamed:
            String(localized: "changes.status.renamed", defaultValue: "renamed", bundle: .module)
        case .untracked:
            String(localized: "changes.status.untracked", defaultValue: "untracked", bundle: .module)
        case .unknown:
            String(localized: "changes.status.unknown", defaultValue: "changed", bundle: .module)
        }
    }
}

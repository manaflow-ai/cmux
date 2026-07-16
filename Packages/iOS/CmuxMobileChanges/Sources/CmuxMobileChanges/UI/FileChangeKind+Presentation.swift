/// Display metadata derived from a file-change category.
extension FileChangeKind {
    /// SF Symbol used by the file list.
    public var symbolName: String {
        switch self {
        case .added: "plus.circle.fill"
        case .untracked: "plus.circle"
        case .modified, .unknown: "pencil.circle.fill"
        case .deleted: "minus.circle.fill"
        case .renamed: "arrow.right.circle.fill"
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

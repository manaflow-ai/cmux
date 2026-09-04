import Foundation

/// The status groups currently exposed by the read-only Source Control panel.
enum SourceControlGroup: String, CaseIterable, Hashable, Sendable {
    case changes
    case untracked

    var title: String {
        switch self {
        case .changes:
            return String(localized: "sourceControl.group.changes", defaultValue: "Changes")
        case .untracked:
            return String(localized: "sourceControl.group.untracked", defaultValue: "Untracked Changes")
        }
    }
}

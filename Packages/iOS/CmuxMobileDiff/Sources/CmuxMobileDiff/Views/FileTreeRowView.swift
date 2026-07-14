internal import CmuxMobileRPC
internal import SwiftUI

/// Value-only row used below the file-tree list boundary.
struct FileTreeRowView: View {
    let row: FileTreeRowSnapshot
    let selectFile: @MainActor @Sendable (String) -> Void
    let toggleDirectory: @MainActor @Sendable (String) -> Void

    var body: some View {
        Button {
            if row.node.kind == .directory {
                toggleDirectory(row.node.id)
            } else {
                selectFile(row.node.id)
            }
        } label: {
            HStack(spacing: 8) {
                Color.clear.frame(width: CGFloat(row.depth) * 14)
                if row.node.kind == .directory {
                    Image(systemName: row.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 12)
                    Image(systemName: "folder")
                        .foregroundStyle(.secondary)
                } else if let file = row.node.file {
                    Circle()
                        .fill(statusColor(file.status))
                        .frame(width: 8, height: 8)
                        .accessibilityLabel(statusLabel(file.status))
                    Image(systemName: "doc.text")
                        .foregroundStyle(.secondary)
                }
                Text(row.node.name)
                    .font(.subheadline)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let file = row.node.file {
                    Text("+\(file.additions)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.green)
                    Text("−\(file.deletions)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.red)
                }
            }
            .contentShape(Rectangle())
            .opacity(row.node.isViewed ? 0.48 : 1)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        guard row.node.kind == .directory else { return row.node.name }
        let format = row.isExpanded
            ? String(localized: "diff.tree.collapseDirectory", defaultValue: "Collapse %@", bundle: .module)
            : String(localized: "diff.tree.expandDirectory", defaultValue: "Expand %@", bundle: .module)
        return String(format: format, locale: .current, row.node.name)
    }

    private func statusColor(_ status: MobileChangesFileStatus) -> Color {
        switch status {
        case .added, .untracked: .green
        case .deleted: .red
        case .renamed, .copied: .blue
        case .modified, .unknown: .orange
        }
    }

    private func statusLabel(_ status: MobileChangesFileStatus) -> String {
        switch status {
        case .added: String(localized: "diff.status.added", defaultValue: "Added", bundle: .module)
        case .modified: String(localized: "diff.status.modified", defaultValue: "Modified", bundle: .module)
        case .deleted: String(localized: "diff.status.deleted", defaultValue: "Deleted", bundle: .module)
        case .renamed: String(localized: "diff.status.renamed", defaultValue: "Renamed", bundle: .module)
        case .copied: String(localized: "diff.status.copied", defaultValue: "Copied", bundle: .module)
        case .untracked: String(localized: "diff.status.untracked", defaultValue: "Untracked", bundle: .module)
        case .unknown: String(localized: "diff.status.changed", defaultValue: "Changed", bundle: .module)
        }
    }
}

#if os(iOS)
import CmuxMobileSupport
import SwiftUI

/// Immutable row renderer below the changes tree's `ForEach` boundary.
struct MobileDiffTreeRowView: View {
    let row: MobileDiffTreeRow
    let isCollapsed: Bool
    let isTooLarge: Bool
    let isSelected: Bool
    let toggleDirectory: (String) -> Void
    let selectFile: (String) -> Void

    var body: some View {
        switch row {
        case let .directory(path, name, depth, fileCount):
            Button { toggleDirectory(path) } label: {
                HStack(spacing: 8) {
                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Image(systemName: "folder")
                        .foregroundStyle(.secondary)
                    Text(name)
                        .foregroundStyle(.primary)
                    Spacer(minLength: 8)
                    Text(fileCountLabel(fileCount))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.leading, CGFloat(depth) * 16)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        case let .file(file, depth):
            Button { selectFile(file.path) } label: {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    statusBadge(file.status)
                    VStack(alignment: .leading, spacing: 3) {
                        if file.status == "R", let oldPath = file.oldPath {
                            Text("\(oldPath) → \(file.path)")
                                .font(.subheadline)
                                .foregroundStyle(.primary)
                                .lineLimit(2)
                        } else {
                            pathLabel(file.path)
                        }
                        if isTooLarge {
                            Text(L10n.string("mobile.diff.tooLarge", defaultValue: "Too large to display"))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        } else if file.binary {
                            Text(L10n.string("mobile.diff.binary", defaultValue: "Binary"))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 6)
                    HStack(spacing: 5) {
                        Text("+\(file.additions)")
                            .foregroundStyle(.green)
                        Text("−\(file.deletions)")
                            .foregroundStyle(.red)
                    }
                    .font(.caption.monospacedDigit())
                }
                .padding(.leading, CGFloat(depth) * 16)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .listRowBackground(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
        }
    }

    private func pathLabel(_ path: String) -> some View {
        let repoPath = MobileDiffPath(path)
        return HStack(spacing: 0) {
            if !repoPath.directory.isEmpty {
                Text(repoPath.directory + "/")
                    .foregroundStyle(.secondary)
            }
            Text(repoPath.fileName)
                .foregroundStyle(.primary)
        }
        .font(.subheadline)
        .lineLimit(2)
    }

    private func statusBadge(_ status: String) -> some View {
        Text(status)
            .font(.caption2.monospaced().weight(.bold))
            .foregroundStyle(statusColor(status))
            .frame(width: 20, height: 20)
            .background(statusColor(status).opacity(0.14), in: RoundedRectangle(cornerRadius: 4))
            .accessibilityLabel(statusAccessibilityLabel(status))
    }

    private func statusColor(_ status: String) -> Color {
        switch status {
        case "A": .green
        case "D": .red
        case "R": .blue
        default: .orange
        }
    }

    private func statusAccessibilityLabel(_ status: String) -> String {
        switch status {
        case "A": L10n.string("mobile.diff.status.added", defaultValue: "Added")
        case "D": L10n.string("mobile.diff.status.deleted", defaultValue: "Deleted")
        case "R": L10n.string("mobile.diff.status.renamed", defaultValue: "Renamed")
        default: L10n.string("mobile.diff.status.modified", defaultValue: "Modified")
        }
    }

    private func fileCountLabel(_ count: Int) -> String {
        if count == 1 {
            return L10n.string("mobile.diff.fileCount.one", defaultValue: "1 file")
        }
        return String(
            format: L10n.string("mobile.diff.fileCount.other", defaultValue: "%d files"),
            count
        )
    }
}
#endif

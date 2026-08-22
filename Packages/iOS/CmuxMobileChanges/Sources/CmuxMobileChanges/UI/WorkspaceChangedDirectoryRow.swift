import SwiftUI

extension ChangedFilesTreeRow {
    /// Shared indentation metric so directory and file rows nest consistently.
    static func indentationWidth(forDepth depth: Int) -> CGFloat {
        CGFloat(depth) * 18
    }
}

struct WorkspaceChangedDirectoryRow: View {
    let row: ChangedFilesTreeRow.DirectoryRowSnapshot
    let onToggle: @MainActor @Sendable (String) -> Void

    var body: some View {
        Button {
            onToggle(row.path)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(row.isExpanded ? 90 : 0))
                Image(systemName: "folder.fill")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(row.displayName)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .leading)
                // The count surfaces only while collapsed, when it is the one
                // signal of how much the fold is hiding.
                if !row.isExpanded {
                    Text(fileCountText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.leading, ChangedFilesTreeRow.indentationWidth(forDepth: row.depth))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("MobileChangesDirRow-\(row.path)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(
            row.isExpanded
                ? String(localized: "changes.dir.expanded", defaultValue: "Expanded", bundle: .module)
                : String(localized: "changes.dir.collapsed", defaultValue: "Collapsed", bundle: .module)
        )
        .accessibilityAddTraits(.isButton)
    }

    private var accessibilityLabel: String {
        String(
            format: String(
                localized: "changes.dir.accessibility",
                defaultValue: "%1$@, folder, %2$@",
                bundle: .module
            ),
            row.displayName,
            fileCountText
        )
    }

    private var fileCountText: String {
        let format: String
        if row.fileCount == 1 {
            format = String(
                localized: "changes.chip.file_count.one",
                defaultValue: "%lld file",
                bundle: .module
            )
        } else {
            format = String(
                localized: "changes.chip.file_count.other",
                defaultValue: "%lld files",
                bundle: .module
            )
        }
        return String(format: format, Int64(row.fileCount))
    }
}

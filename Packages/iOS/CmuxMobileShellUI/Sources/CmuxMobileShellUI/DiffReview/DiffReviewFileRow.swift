import CmuxMobileRPC
import CmuxMobileSupport
import SwiftUI

struct DiffReviewFileRow: View {
    let file: MobileWorkspaceDiffStatusResponse.File
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 8) {
                statusBadge
                VStack(alignment: .leading, spacing: 1) {
                    Text(fileName)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if !directory.isEmpty {
                        Text(directory)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 4)
                counts
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .frame(minHeight: 48)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(
            L10n.string("mobile.diff.openFileHint", defaultValue: "Opens this file's diff")
        )
        .accessibilityIdentifier("DiffReviewFileRow-\(file.path)")
    }

    private var statusBadge: some View {
        HStack(spacing: 2) {
            Image(systemName: statusSymbol)
                .font(.caption2.weight(.bold))
            Text(verbatim: file.status)
                .font(.caption2.monospaced().bold())
        }
        .foregroundStyle(statusColor)
        .frame(width: 34, height: 28)
        .background(statusColor.opacity(0.14), in: .rect(cornerRadius: 6))
    }

    @ViewBuilder
    private var counts: some View {
        HStack(spacing: 4) {
            if let additions = file.additions {
                Label {
                    Text(verbatim: "+\(additions)")
                } icon: {
                    Image(systemName: "plus")
                        .accessibilityHidden(true)
                }
                .foregroundStyle(.green)
            }
            if let deletions = file.deletions {
                Label {
                    Text(verbatim: "−\(deletions)")
                } icon: {
                    Image(systemName: "minus")
                        .accessibilityHidden(true)
                }
                .foregroundStyle(.red)
            }
        }
        .labelStyle(.titleOnly)
        .font(.caption2.monospaced().monospacedDigit())
    }

    private var fileName: String {
        URL(fileURLWithPath: file.path).lastPathComponent
    }

    private var directory: String {
        let directory = (file.path as NSString).deletingLastPathComponent
        return directory == "." ? "" : directory
    }

    private var statusSymbol: String {
        switch file.status {
        case "A", "U": "plus"
        case "D": "minus"
        case "R": "arrow.right"
        default: "pencil"
        }
    }

    private var statusColor: Color {
        switch file.status {
        case "A", "U": .green
        case "D": .red
        case "R": .blue
        default: .orange
        }
    }

    private var statusAccessibilityText: String {
        switch file.status {
        case "A": L10n.string("mobile.diff.status.added", defaultValue: "Added")
        case "D": L10n.string("mobile.diff.status.deleted", defaultValue: "Deleted")
        case "R": L10n.string("mobile.diff.status.renamed", defaultValue: "Renamed")
        case "U": L10n.string("mobile.diff.status.untracked", defaultValue: "Untracked")
        default: L10n.string("mobile.diff.status.modified", defaultValue: "Modified")
        }
    }

    private var accessibilityLabel: String {
        let additions =
            file.additions.map {
                String(
                    format: L10n.string(
                        "mobile.diff.additionsAccessibilityFormat", defaultValue: "%d additions"),
                    $0
                )
            }
            ?? L10n.string(
                "mobile.diff.additionCountUnavailable",
                defaultValue: "addition count unavailable"
            )
        let deletions =
            file.deletions.map {
                String(
                    format: L10n.string(
                        "mobile.diff.deletionsAccessibilityFormat", defaultValue: "%d deletions"),
                    $0
                )
            }
            ?? L10n.string(
                "mobile.diff.deletionCountUnavailable",
                defaultValue: "deletion count unavailable"
            )
        return String(
            format: L10n.string(
                "mobile.diff.fileAccessibilityFormat",
                defaultValue: "%1$@, %2$@, %3$@, %4$@"
            ),
            statusAccessibilityText,
            file.path,
            additions,
            deletions
        )
    }
}

import CmuxDiffModel
import CmuxMobileSupport
import SwiftUI

struct DiffReviewFileRow: View {
    let file: DiffFileSummary
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
            Text(verbatim: file.status.rawValue)
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
        case .added, .untracked: "plus"
        case .deleted: "minus"
        case .renamed: "arrow.right"
        case .modified: "pencil"
        }
    }

    private var statusColor: Color {
        switch file.status {
        case .added, .untracked: .green
        case .deleted: .red
        case .renamed: .blue
        case .modified: .orange
        }
    }

    private var statusAccessibilityText: String {
        switch file.status {
        case .added: L10n.string("mobile.diff.status.added", defaultValue: "Added")
        case .deleted: L10n.string("mobile.diff.status.deleted", defaultValue: "Deleted")
        case .renamed: L10n.string("mobile.diff.status.renamed", defaultValue: "Renamed")
        case .untracked: L10n.string("mobile.diff.status.untracked", defaultValue: "Untracked")
        case .modified: L10n.string("mobile.diff.status.modified", defaultValue: "Modified")
        }
    }

    private var accessibilityLabel: String {
        let additions =
            file.additions.map { count in
                if count == 1 {
                    return L10n.string(
                        "mobile.diff.additionsAccessibility.one",
                        defaultValue: "1 addition"
                    )
                }
                return L10n.string(
                    "mobile.diff.additionsAccessibility.other",
                    defaultValue: "\(count) additions"
                )
            }
            ?? L10n.string(
                "mobile.diff.additionCountUnavailable",
                defaultValue: "addition count unavailable"
            )
        let deletions =
            file.deletions.map { count in
                if count == 1 {
                    return L10n.string(
                        "mobile.diff.deletionsAccessibility.one",
                        defaultValue: "1 deletion"
                    )
                }
                return L10n.string(
                    "mobile.diff.deletionsAccessibility.other",
                    defaultValue: "\(count) deletions"
                )
            }
            ?? L10n.string(
                "mobile.diff.deletionCountUnavailable",
                defaultValue: "deletion count unavailable"
            )
        return L10n.string(
            "mobile.diff.fileAccessibilityFormat",
            defaultValue: "\(statusAccessibilityText), \(file.path), \(additions), \(deletions)"
        )
    }
}

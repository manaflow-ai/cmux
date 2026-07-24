import SwiftUI

struct WorkspaceChangedFileRow: View {
    let snapshot: ChangedFileRowSnapshot
    let theme: ChangesTheme
    let onSelect: @MainActor @Sendable (Int) -> Void

    var body: some View {
        Button {
            onSelect(snapshot.index)
        } label: {
            HStack(spacing: 10) {
                // No leading status pictograms: the counts and mini-bar carry
                // magnitude, and only exceptional kinds get a quiet text badge
                // so ordinary modified rows stay completely calm.
                HStack(spacing: 6) {
                    pathText
                        .lineLimit(snapshot.file.kind == .renamed ? 2 : 1)
                        .truncationMode(.head)
                    if let badge = snapshot.file.kind.badge {
                        badgeView(badge)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .trailing, spacing: 5) {
                    if snapshot.file.isBinary {
                        Text(String(localized: "changes.binary.badge", defaultValue: "BIN", bundle: .module))
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.14), in: Capsule())
                    } else {
                        HStack(spacing: 5) {
                            Text(additionsText)
                                .foregroundStyle(theme.addedStatus)
                            Text(deletionsText)
                                .foregroundStyle(theme.deletedStatus)
                        }
                        .font(.caption.monospacedDigit())
                        ChangesMiniBar(
                            additions: snapshot.file.additions,
                            deletions: snapshot.file.deletions,
                            theme: theme
                        )
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("MobileChangesRow-\(snapshot.file.path)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(snapshot.file.accessibilityLabel)
    }

    private var pathText: Text {
        if snapshot.file.kind == .renamed {
            return Text(snapshot.file.displayFilename).fontWeight(.semibold)
        }
        // A deleted file's whole path dims: the row is a record of something
        // gone, so nothing in it competes with living files while scanning.
        if snapshot.file.kind == .deleted {
            return (Text(snapshot.file.directoryPrefix)
                + Text(snapshot.file.filename).fontWeight(.semibold))
                .foregroundColor(.secondary)
        }
        return Text(snapshot.file.directoryPrefix).foregroundColor(.secondary)
            + Text(snapshot.file.filename).fontWeight(.semibold)
    }

    private func badgeView(_ badge: FileChangeBadge) -> some View {
        Text(badge.text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(badge.role == .new ? theme.addedStatus : theme.deletedStatus)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                badge.role == .new ? theme.additionBackground : theme.removalBackground,
                in: Capsule()
            )
            .accessibilityHidden(true)
    }

    private var additionsText: String {
        String(
            format: String(localized: "changes.summary.additions", defaultValue: "+%lld", bundle: .module),
            Int64(snapshot.file.additions)
        )
    }

    private var deletionsText: String {
        String(
            format: String(localized: "changes.summary.deletions", defaultValue: "−%lld", bundle: .module),
            Int64(snapshot.file.deletions)
        )
    }
}

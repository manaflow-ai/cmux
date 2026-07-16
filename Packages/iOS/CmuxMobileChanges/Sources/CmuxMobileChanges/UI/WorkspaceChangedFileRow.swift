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
                Image(systemName: snapshot.file.kind.symbolName)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(theme.statusColor(for: snapshot.file.kind))
                    .frame(width: 22)
                pathText
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(snapshot.file.kind == .renamed ? 2 : 1)
                    .truncationMode(.head)
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
        return Text(snapshot.file.directoryPrefix).foregroundColor(.secondary)
            + Text(snapshot.file.filename).fontWeight(.semibold)
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

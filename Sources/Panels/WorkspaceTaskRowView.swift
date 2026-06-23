import SwiftUI

struct WorkspaceTaskRowView: View {
    let task: WorkspaceTask
    let canArchive: Bool
    let canMoveUp: Bool
    let canMoveDown: Bool
    let archive: () -> Void
    let remove: () -> Void
    let moveUp: () -> Void
    let moveDown: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if canArchive {
                Button(action: archive) {
                    Image(systemName: "checkmark.circle")
                        .cmuxSymbolRasterSize(14)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .help(String(localized: "workspaceTasks.complete.help", defaultValue: "Complete task"))
                .accessibilityLabel(String(localized: "workspaceTasks.complete.label", defaultValue: "Complete Task"))
            } else {
                Image(systemName: "archivebox")
                    .cmuxSymbolRasterSize(13)
                    .foregroundStyle(.tertiary)
                    .frame(width: 24, height: 24)
                    .accessibilityHidden(true)
            }

            Text(task.title)
                .cmuxFont(.body)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)

            WorkspaceTaskIconButton(
                systemName: "chevron.up",
                label: String(localized: "workspaceTasks.moveUp.label", defaultValue: "Move Task Up"),
                isDisabled: !canMoveUp,
                action: moveUp
            )
            WorkspaceTaskIconButton(
                systemName: "chevron.down",
                label: String(localized: "workspaceTasks.moveDown.label", defaultValue: "Move Task Down"),
                isDisabled: !canMoveDown,
                action: moveDown
            )
            WorkspaceTaskIconButton(
                systemName: "trash",
                label: String(localized: "workspaceTasks.remove.label", defaultValue: "Remove Task"),
                role: .destructive,
                action: remove
            )
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.72))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .stroke(Color(nsColor: .separatorColor).opacity(0.35), lineWidth: 1)
        }
    }
}

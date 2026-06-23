import SwiftUI

struct WorkspaceTaskRowView: View {
    let task: WorkspaceTask
    let canArchive: Bool
    let canMoveUp: Bool
    let canMoveDown: Bool
    let archive: () -> Void
    let unarchive: () -> Void
    let remove: () -> Void
    let moveUp: () -> Void
    let moveDown: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

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
                Button(action: unarchive) {
                    Image(systemName: "arrow.uturn.backward.circle")
                        .cmuxSymbolRasterSize(14)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .help(String(localized: "workspaceTasks.restore.help", defaultValue: "Restore task"))
                .accessibilityLabel(String(localized: "workspaceTasks.restore.label", defaultValue: "Restore Task"))
            }

            Text(task.title)
                .cmuxFont(.body)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)

            Image(systemName: "line.3.horizontal")
                .cmuxSymbolRasterSize(12, weight: .medium)
                .foregroundStyle(.tertiary)
                .frame(width: 20, height: 22)
                .opacity(isHovering ? 1 : 0.38)
                .help(String(localized: "workspaceTasks.dragHandle.help", defaultValue: "Drag to reorder"))
                .accessibilityHidden(true)

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
                .fill(Color(nsColor: .controlBackgroundColor).opacity(isHovering ? 0.9 : 0.68))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .stroke(Color(nsColor: .separatorColor).opacity(isHovering ? 0.55 : 0.3), lineWidth: 1)
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .animation(hoverAnimation, value: isHovering)
        .accessibilityAction(named: Text(String(localized: "workspaceTasks.moveUp.label", defaultValue: "Move Task Up"))) {
            guard canMoveUp else { return }
            moveUp()
        }
        .accessibilityAction(named: Text(String(localized: "workspaceTasks.moveDown.label", defaultValue: "Move Task Down"))) {
            guard canMoveDown else { return }
            moveDown()
        }
    }

    private var hoverAnimation: Animation? {
        reduceMotion ? nil : .easeOut(duration: 0.12)
    }
}

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
        HStack(alignment: .firstTextBaseline, spacing: 11) {
            completionButton

            Text(task.title)
                .cmuxFont(.body)
                .foregroundStyle(canArchive ? .primary : .secondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)

            CmuxSystemSymbolImage(magnified: "line.3.horizontal", pointSize: 12, weight: .medium)
                .foregroundStyle(.tertiary)
                .frame(width: 18, height: 22)
                .opacity(isHovering && canArchive ? 0.9 : 0)
                .help(String(localized: "workspaceTasks.dragHandle.help", defaultValue: "Drag to reorder"))
                .accessibilityHidden(true)

            if !canArchive {
                WorkspaceTaskIconButton(
                    systemName: "arrow.uturn.backward",
                    label: String(localized: "workspaceTasks.restore.label", defaultValue: "Restore Task"),
                    foregroundStyle: taskAccent,
                    action: unarchive
                )
            }

            WorkspaceTaskIconButton(
                systemName: "trash",
                label: String(localized: "workspaceTasks.remove.label", defaultValue: "Remove Task"),
                role: .destructive,
                foregroundStyle: .secondary,
                action: remove
            )
            .opacity(isHovering ? 0.86 : 0)
            .allowsHitTesting(isHovering)
            .accessibilityHidden(!isHovering)
        }
        .padding(.horizontal, 2)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(isHovering ? 0.56 : 0))
        )
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color(nsColor: .separatorColor).opacity(0.24))
                .frame(height: 1)
                .padding(.leading, 32)
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
        .accessibilityAction(named: Text(String(localized: "workspaceTasks.remove.label", defaultValue: "Remove Task"))) {
            remove()
        }
    }

    private var hoverAnimation: Animation? {
        reduceMotion ? nil : .easeOut(duration: 0.12)
    }

    private var completionButton: some View {
        Button(action: canArchive ? archive : unarchive) {
            ZStack {
                Circle()
                    .stroke(
                        canArchive ? taskAccent.opacity(isHovering ? 0.82 : 0.48) : Color.secondary.opacity(0.42),
                        lineWidth: 1.35
                    )
                    .background(
                        Circle()
                            .fill(canArchive ? taskAccent.opacity(isHovering ? 0.1 : 0) : Color.secondary.opacity(0.08))
                )
                if !canArchive {
                    CmuxSystemSymbolImage(magnified: "checkmark", pointSize: 8, weight: .semibold)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 18, height: 18)
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
            .scaleEffect(isHovering && canArchive ? 1.06 : 1)
        }
        .buttonStyle(.plain)
        .help(canArchive
              ? String(localized: "workspaceTasks.complete.help", defaultValue: "Complete task")
              : String(localized: "workspaceTasks.restore.help", defaultValue: "Restore task"))
        .accessibilityLabel(canArchive
                            ? String(localized: "workspaceTasks.complete.label", defaultValue: "Complete Task")
                            : String(localized: "workspaceTasks.restore.label", defaultValue: "Restore Task"))
    }

    private var taskAccent: Color {
        Color(red: 0.86, green: 0.25, blue: 0.19)
    }
}

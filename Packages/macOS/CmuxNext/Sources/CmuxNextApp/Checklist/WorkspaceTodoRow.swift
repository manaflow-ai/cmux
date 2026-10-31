import CmuxNextDaemon
import CmuxNextDesign
import SwiftUI
import CmuxNextTasks

/// One checklist item on the Todo page: its state mark (click toggles complete), its text
/// (double-click edits), how many images it has, and a menu of its actions.
struct WorkspaceTodoRow: View {
    let item: WorkspaceChecklistItem
    let isEditing: Bool
    let actions: WorkspaceTodoRowActions
    @State private var text = ""

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Button { actions.toggle(item.id) } label: {
                Image(systemName: Self.symbol(item.state))
                    .foregroundStyle(item.state == .done ? Color(nsColor: Palette.litGlyph) : Color.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(WorkspaceChecklistStrings.toggle)
            if isEditing {
                TextField(WorkspaceChecklistStrings.addPlaceholder, text: $text)
                    .textFieldStyle(.plain)
                    .focusEffectDisabled()
                    .onAppear { text = item.text }
                    .onSubmit { actions.commitEdit(item.id, text) }
                    .onExitCommand { actions.cancelEdit() }
            } else {
                Text(item.text)
                    .strikethrough(item.state == .done)
                    .foregroundStyle(item.state == .done ? Color.secondary : Color.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { actions.beginEdit(item.id) }
            }
            if !item.attachments.isEmpty {
                Label { Text(verbatim: "\(item.attachments.count)") } icon: { Image(systemName: "photo") }
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.secondary)
                    .themedHelp(item.attachments.map(\.name).joined(separator: "\n"))
            }
        }
        .padding(.vertical, 4)
        .contextMenu {
            if item.state != .inProgress {
                Button(WorkspaceChecklistStrings.markInProgress) { actions.setState(item.id, .inProgress) }
            }
            if item.state == .done {
                Button(WorkspaceChecklistStrings.markTodo) { actions.setState(item.id, .todo) }
            } else {
                Button(WorkspaceChecklistStrings.complete) { actions.setState(item.id, .done) }
            }
            Button(WorkspaceChecklistStrings.edit) { actions.beginEdit(item.id) }
            Button(WorkspaceChecklistStrings.attachImages) { actions.attachImages(item.id) }
            Divider()
            Button(WorkspaceChecklistStrings.remove, role: .destructive) { actions.remove(item.id) }
        }
    }

    static func symbol(_ state: WorkspaceChecklistItem.State) -> String {
        switch state {
        case .todo: "circle"
        case .inProgress: "circle.lefthalf.filled"
        case .done: "checkmark.circle.fill"
        }
    }
}

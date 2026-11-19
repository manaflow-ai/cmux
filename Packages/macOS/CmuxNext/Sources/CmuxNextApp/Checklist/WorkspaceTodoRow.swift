import CmuxNextChecklist
import CmuxNextDaemon
import CmuxNextDesign
import CmuxVisibleRows
import SwiftUI

/// One checklist item on the Todo page: its state mark (click toggles complete), its text
/// (double-click edits), how many images it has, and a menu of its actions.
struct WorkspaceTodoRow: View, Equatable {
    let item: WorkspaceChecklistItem
    let isEditing: Bool
    let actions: WorkspaceTodoRowActions
    @State private var text = ""
    let work: ListWorkMeter // the page's ``WorkspaceTodoPageModel/listWork``: each body counts one row configured

    /// Equal when the item and its edit state are: the page makes `actions` again with each body.
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.item == rhs.item && lhs.isEditing == rhs.isEditing }

    var body: some View {
        work.configured()
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Button { actions.toggle(item.id) } label: {
                Image(systemName: Self.symbol(item.state))
                    .foregroundStyle(item.state == .done ? Color(nsColor: Palette.litGlyph) : Color.secondary)
            }
            .buttonStyle(.cmuxPressFill)
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

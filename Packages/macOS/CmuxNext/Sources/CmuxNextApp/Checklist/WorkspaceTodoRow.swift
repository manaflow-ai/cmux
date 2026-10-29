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

    /// One row as an AppKit view (its `NSHostingView`), for AppKit callers and tests.
    static func hostingView(item: WorkspaceChecklistItem, isEditing: Bool, actions: WorkspaceTodoRowActions) -> NSView {
        NSHostingView(rootView: WorkspaceTodoRow(item: item, isEditing: isEditing, actions: actions))
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Button { actions.toggle(item.id) } label: {
                Image(systemName: Self.symbol(item.state))
                    .foregroundStyle(item.state == .done ? Color(nsColor: Palette.litGlyph) : Color.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(WorkspaceChecklistStrings.toggle)
            if isEditing {
                WorkspaceTodoEditField(item: item, actions: actions)
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

/// The text field of an item being edited. Its text starts as the item's when the edit begins (the
/// field is made), not on appear: a gated page tab appears again on each show
/// (`VisibilityGatedHostingView`), and the text typed so far must stay.
private struct WorkspaceTodoEditField: View {
    let item: WorkspaceChecklistItem
    let actions: WorkspaceTodoRowActions
    @State private var text: String

    init(item: WorkspaceChecklistItem, actions: WorkspaceTodoRowActions) {
        (self.item, self.actions) = (item, actions)
        _text = State(initialValue: item.text)
    }

    var body: some View {
        TextField(WorkspaceChecklistStrings.addPlaceholder, text: $text).textFieldStyle(.plain).focusEffectDisabled()
            .onSubmit { actions.commitEdit(item.id, text) }.onExitCommand { actions.cancelEdit() }
    }
}

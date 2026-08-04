import CMUXMobileCore
import CmuxMobileSupport
import SwiftUI

/// Closure bundle for an immutable mobile todo row snapshot.
struct TodoSurfaceRowActions {
    let cycleState: () -> Void
    let edit: (String) -> Void
    let move: (String, Int) -> Void
    let remove: () -> Void
}

/// One immutable checklist row with local-only inline editing state.
struct TodoSurfaceRowView: View {
    let item: MobileTodoItem
    let displayIndex: Int
    let isEnabled: Bool
    let actions: TodoSurfaceRowActions

    @State private var isEditing = false
    @State private var draft = ""
    @FocusState private var editorFocused: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Button(action: actions.cycleState) {
                Image(systemName: stateSystemImage)
                    .foregroundStyle(item.state == .completed ? .secondary : .primary)
            }
            .buttonStyle(.plain)
            .disabled(!isEnabled)
            .accessibilityLabel(stateActionLabel)

            if isEditing {
                TextField(
                    L10n.string("mobile.todo.item.editPlaceholder", defaultValue: "Item text"),
                    text: $draft,
                    axis: .vertical
                )
                .focused($editorFocused)
                .lineLimit(1...6)
                .onSubmit(commitEdit)
                .onChange(of: editorFocused) { _, focused in
                    if !focused { commitEdit() }
                }
            } else {
                Text(item.text)
                    .strikethrough(item.state == .completed)
                    .foregroundStyle(item.state == .completed ? .secondary : .primary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            if item.origin == .agent {
                Image(systemName: "sparkles")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(L10n.string(
                        "mobile.todo.item.agentOrigin",
                        defaultValue: "Created by an agent"
                    ))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if !isEditing { beginEdit() }
        }
        .draggable(item.id)
        .dropDestination(for: String.self) { draggedIDs, _ in
            guard isEnabled, let draggedID = draggedIDs.first else { return false }
            actions.move(draggedID, displayIndex)
            return true
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive, action: actions.remove) {
                Label(
                    L10n.string("mobile.todo.item.delete", defaultValue: "Delete"),
                    systemImage: "trash"
                )
            }
            .disabled(!isEnabled)
        }
    }

    private var stateSystemImage: String {
        switch item.state {
        case .pending: "square"
        case .inProgress: "minus.square"
        case .completed: "checkmark.square.fill"
        }
    }

    private var stateActionLabel: String {
        switch item.state.next {
        case .pending:
            L10n.string("mobile.todo.item.markPending", defaultValue: "Mark as pending")
        case .inProgress:
            L10n.string("mobile.todo.item.markInProgress", defaultValue: "Mark as in progress")
        case .completed:
            L10n.string("mobile.todo.item.markCompleted", defaultValue: "Mark as completed")
        }
    }

    private func beginEdit() {
        guard isEnabled else { return }
        draft = item.text
        isEditing = true
        editorFocused = true
    }

    private func commitEdit() {
        guard isEditing else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        isEditing = false
        editorFocused = false
        if !text.isEmpty, text != item.text {
            actions.edit(text)
        }
    }
}

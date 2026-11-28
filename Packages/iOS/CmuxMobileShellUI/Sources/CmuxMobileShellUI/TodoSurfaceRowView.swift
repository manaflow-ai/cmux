import CMUXMobileCore
import CmuxMobileSupport
import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

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
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Button {
                #if canImport(UIKit)
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                #endif
                actions.cycleState()
            } label: {
                Image(systemName: stateSystemImage)
                    .font(.title3)
                    .foregroundStyle(stateTint)
                    .contentTransition(.symbolEffect(.replace))
                    .animation(.snappy, value: item.state)
                    .frame(width: 26, height: 26)
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
                    .strikethrough(item.state == .completed, color: .secondary)
                    .foregroundStyle(item.state == .completed ? .secondary : .primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .animation(.snappy, value: item.state)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
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
        case .pending: "circle"
        case .inProgress: "circle.lefthalf.filled"
        case .completed: "checkmark.circle.fill"
        }
    }

    private var stateTint: AnyShapeStyle {
        switch item.state {
        case .pending: AnyShapeStyle(.tertiary)
        case .inProgress: AnyShapeStyle(.tint)
        case .completed: AnyShapeStyle(MobileTodoStatus.done.tint)
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

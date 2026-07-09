import AppKit
import CmuxWorkspaces
import SwiftUI

/// Top-level SwiftUI view for a ``WorkspaceTodoPanel``: a header (clickable
/// status glyph, workspace title, lane name, progress) over the full
/// unclamped checklist with a pinned add field.
///
/// Unlike the sidebar rows, this pane is NOT under the sidebar lazy-list
/// snapshot boundary, so it observes the `Workspace` and its
/// `WorkspaceTodoState` objects directly (mirroring how `MarkdownPanelView`
/// observes its panel); mutations still route through the shared
/// `WorkspaceTodoActions` / `Workspace+Todos` entry points. The header glyph
/// opens the same `SidebarWorkspaceStatusPopover` through the shared
/// NSPopover host, anchored in-pane.
struct WorkspaceTodoPanelView: View {
    @ObservedObject var panel: WorkspaceTodoPanel
    let isFocused: Bool
    let onRequestPanelFocus: () -> Void

    var body: some View {
        Group {
            if let workspace = panel.workspace {
                WorkspaceTodoPaneContent(
                    workspace: workspace,
                    todoState: workspace.todoState,
                    isFocused: isFocused
                )
            } else {
                Text(String(
                    localized: "workspaceTodoPane.workspaceUnavailable",
                    defaultValue: "This workspace is no longer available."
                ))
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(NSColor.windowBackgroundColor))
        .contentShape(Rectangle())
        .onTapGesture { onRequestPanelFocus() }
    }
}

/// The pane body once the workspace is resolved. Observes the workspace (for
/// title and inferred-status recomputes) and its todo state (for override and
/// checklist churn) directly.
private struct WorkspaceTodoPaneContent: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var todoState: WorkspaceTodoState
    let isFocused: Bool

    @State private var isStatusPopoverPresented = false
    @State private var pendingItemText = ""
    @FocusState private var addFieldFocused: Bool
    @State private var editingItemId: UUID?
    @State private var editingText = ""
    @FocusState private var editFieldFocused: Bool
    /// The keyboard-highlighted item (Up/Down arrows); Return or Cmd+Return
    /// toggles it.
    @State private var highlightedItemId: UUID?
    @FocusState private var itemsFocused: Bool

    private static let itemFontSize: CGFloat = 13
    private static let checkboxPointSize: CGFloat = 13
    /// Header glyph draws at ~13pt (the sidebar glyph's base size is 9pt).
    private static let headerGlyphFontScale: CGFloat = 13.0 / 9.0

    var body: some View {
        // Pure reads: effective-status resolution never mutates (the
        // expired-override cleanup happens at mutation entry points).
        let inferred = workspace.inferredTaskStatus
        let resolution = WorkspaceTaskStatusOverride.effectiveStatus(
            override: todoState.statusOverride,
            inferred: inferred
        )
        let hasOverride = todoState.statusOverride != nil && !resolution.shouldClearOverride
        let progress = todoState.checklist.checklistProgressSummary

        VStack(alignment: .leading, spacing: 0) {
            header(
                effective: resolution.effective,
                inferred: inferred,
                hasOverride: hasOverride,
                progress: progress
            )
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            Divider()
            let ordered = SidebarWorkspaceChecklistDisplayPolicy.orderedItems(todoState.checklist)
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 3) {
                    if ordered.isEmpty {
                        Text(String(
                            localized: "workspaceTodoPane.emptyChecklist",
                            defaultValue: "No checklist items yet."
                        ))
                        .font(.system(size: Self.itemFontSize))
                        .foregroundColor(.secondary)
                        .padding(.vertical, 4)
                    }
                    ForEach(Array(ordered.enumerated()), id: \.element.id) { index, item in
                        itemRow(item, displayIndex: index)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .focusable(!ordered.isEmpty)
            .focused($itemsFocused)
            .onKeyPress(.upArrow) { moveHighlight(-1, in: ordered) }
            .onKeyPress(.downArrow) { moveHighlight(1, in: ordered) }
            .onKeyPress { press in handleItemsKeyPress(press, ordered: ordered) }
            Divider()
            addItemRow
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
        }
        // The add field is armed whenever the pane holds focus, so typing a
        // new item needs zero extra clicks after `cmux todo open`.
        .onAppear { if isFocused { addFieldFocused = true } }
        .onChange(of: isFocused) { _, focused in
            if focused, editingItemId == nil { addFieldFocused = true }
        }
        .onChange(of: editFieldFocused) { _, focused in
            if !focused { finishItemEditOnFocusLoss() }
        }
        .accessibilityIdentifier("WorkspaceTodoPane")
    }

    // MARK: Header

    private func header(
        effective: WorkspaceTaskStatus,
        inferred: WorkspaceTaskStatus,
        hasOverride: Bool,
        progress: WorkspaceChecklistProgressSummary
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Button {
                isStatusPopoverPresented.toggle()
            } label: {
                SidebarWorkspaceTaskStatusGlyph(
                    status: effective,
                    hasOverride: hasOverride,
                    usesMonochrome: false,
                    monochromeColor: .primary,
                    neutralColor: .secondary,
                    fontScale: Self.headerGlyphFontScale
                )
                .contentShape(Rectangle().inset(by: -3))
            }
            .buttonStyle(.plain)
            .background(
                SidebarWorkspaceTodoPopoverHost(
                    isPresented: $isStatusPopoverPresented,
                    model: SidebarWorkspaceStatusPopoverModel(
                        inferred: inferred,
                        activeOverride: hasOverride ? effective : nil
                    ),
                    minWidth: 200,
                    maxHeight: 400,
                    preferredEdge: .maxY
                ) { model, close in
                    SidebarWorkspaceStatusPopover(
                        model: model,
                        onSelectLane: { [workspace] status in
                            WorkspaceTodoActions.applyStatusOverride(status, to: [workspace])
                        },
                        onSelectNone: { [workspace] in
                            WorkspaceTodoActions.hideStatus(for: [workspace])
                        },
                        onClose: close
                    )
                }
            )
            .accessibilityIdentifier("WorkspaceTodoPaneStatusGlyph")
            Text(workspace.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
            Text(effective.displayName)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            Spacer(minLength: 8)
            if progress.totalCount > 0 {
                Text(verbatim: "\(progress.completedCount)/\(progress.totalCount)")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: Items

    private func itemRow(_ item: WorkspaceChecklistItem, displayIndex: Int) -> some View {
        let isCompleted = item.state == .completed
        return WorkspaceTodoPaneItemRow(
            item: item,
            displayIndex: displayIndex,
            isEditing: editingItemId == item.id,
            isHighlighted: highlightedItemId == item.id,
            editingText: $editingText,
            editFieldFocused: $editFieldFocused,
            itemFontSize: Self.itemFontSize,
            checkboxPointSize: Self.checkboxPointSize,
            actions: WorkspaceTodoPaneItemRowActions(
                toggleCompletion: {
                    WorkspaceTodoActions.setChecklistItemState(
                        id: item.id,
                        state: isCompleted ? .pending : .completed,
                        in: workspace
                    )
                },
                beginEdit: { beginItemEdit(item) },
                commitEdit: { commitItemEdit(item.id) },
                cancelEdit: cancelItemEdit,
                select: {
                    highlightedItemId = item.id
                    itemsFocused = true
                },
                markInProgress: {
                    WorkspaceTodoActions.setChecklistItemState(id: item.id, state: .inProgress, in: workspace)
                },
                remove: {
                    WorkspaceTodoActions.removeChecklistItem(id: item.id, from: workspace)
                },
                handleDrop: { payload, displayIndex in
                    handleReorderDrop(payload: payload, onto: displayIndex)
                }
            )
        )
    }

    // MARK: Keyboard navigation + reorder

    /// Moves the highlight up/down through the visible (display-ordered)
    /// items, clamping at the ends.
    private func moveHighlight(_ delta: Int, in ordered: [WorkspaceChecklistItem]) -> KeyPress.Result {
        guard !ordered.isEmpty else { return .ignored }
        let currentIndex = ordered.firstIndex(where: { $0.id == highlightedItemId })
            ?? (delta > 0 ? -1 : ordered.count)
        let next = min(max(currentIndex + delta, 0), ordered.count - 1)
        highlightedItemId = ordered[next].id
        return .handled
    }

    /// Return or Cmd+Return toggles the highlighted item between completed and pending.
    /// The action is also registered as the `toggleChecklistItemComplete`
    /// shortcut for Settings discoverability via Cmd+Return; the pane handles
    /// the keystroke locally because the toggle needs the view-local highlight.
    private func handleItemsKeyPress(
        _ press: KeyPress,
        ordered: [WorkspaceChecklistItem]
    ) -> KeyPress.Result {
        guard press.key == .return,
              press.modifiers.isEmpty || press.modifiers.contains(.command) else {
            return .ignored
        }
        // Plain Return must fall through to a live in-row edit's onSubmit
        // (the edit TextField is a descendant of this handler's scope).
        if press.modifiers.isEmpty, editingItemId != nil {
            return .ignored
        }
        guard let id = highlightedItemId,
              let item = ordered.first(where: { $0.id == id }) else { return .ignored }
        WorkspaceTodoActions.setChecklistItemState(
            id: item.id,
            state: item.state == .completed ? .pending : .completed,
            in: workspace
        )
        return .handled
    }

    /// Resolves a reorder drop: move the dragged item to the dropped-on row's
    /// display position (the model clamps into the item's completion group).
    private func handleReorderDrop(payload: [String], onto displayIndex: Int) -> Bool {
        guard let raw = payload.first, let id = UUID(uuidString: raw) else { return false }
        WorkspaceTodoActions.moveChecklistItem(id: id, toIndex: displayIndex, in: workspace)
        return true
    }

    // MARK: Add-item row (pinned at the bottom, always armed)

    private var addItemRow: some View {
        HStack(alignment: .center, spacing: 7) {
            // A `plus.circle` "add" affordance, not an empty checkbox, so the
            // add row never reads as a real (unchecked) item.
            CmuxSystemSymbolImage(systemName: "plus.circle", pointSize: Self.checkboxPointSize)
                .foregroundColor(.secondary)
            TextField(
                String(localized: "sidebar.checklist.addItemPlaceholder", defaultValue: "New checklist item"),
                text: $pendingItemText
            )
            .font(.system(size: Self.itemFontSize))
            .textFieldStyle(.plain)
            .foregroundColor(.primary)
            .focused($addFieldFocused)
            .onSubmit(commitPendingItem)
            .onExitCommand(perform: cancelPendingItem)
            .accessibilityIdentifier("WorkspaceTodoPaneAddItemField")
        }
    }

    /// Enter commits the trimmed text and re-arms the field for the next item.
    private func commitPendingItem() {
        let text = pendingItemText
        pendingItemText = ""
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        WorkspaceTodoActions.addChecklistItem(text: text, to: workspace)
        addFieldFocused = true
    }

    /// Esc clears a partial entry and releases keyboard focus.
    private func cancelPendingItem() {
        pendingItemText = ""
        addFieldFocused = false
    }

    // MARK: Item text editing

    private func beginItemEdit(_ item: WorkspaceChecklistItem) {
        editingItemId = item.id
        editingText = item.text
        editFieldFocused = true
    }

    /// Enter commits the trimmed replacement text; empty keeps the old text.
    private func commitItemEdit(_ id: UUID) {
        let text = editingText
        cancelItemEdit()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        WorkspaceTodoActions.editChecklistItem(id: id, text: text, in: workspace)
    }

    private func finishItemEditOnFocusLoss() {
        guard let id = editingItemId else { return }
        let text = editingText
        editingItemId = nil
        editingText = ""
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        WorkspaceTodoActions.editChecklistItem(id: id, text: text, in: workspace)
    }

    private func cancelItemEdit() {
        editingItemId = nil
        editingText = ""
        editFieldFocused = false
    }
}

private struct WorkspaceTodoPaneItemRowActions {
    let toggleCompletion: () -> Void
    let beginEdit: () -> Void
    let commitEdit: () -> Void
    let cancelEdit: () -> Void
    let select: () -> Void
    let markInProgress: () -> Void
    let remove: () -> Void
    let handleDrop: ([String], Int) -> Bool
}

private struct WorkspaceTodoPaneItemRow: View {
    let item: WorkspaceChecklistItem
    let displayIndex: Int
    let isEditing: Bool
    let isHighlighted: Bool
    @Binding var editingText: String
    let editFieldFocused: FocusState<Bool>.Binding
    let itemFontSize: CGFloat
    let checkboxPointSize: CGFloat
    let actions: WorkspaceTodoPaneItemRowActions

    private var isCompleted: Bool { item.state == .completed }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Button {
                actions.toggleCompletion()
            } label: {
                CmuxSystemSymbolImage(
                    systemName: checkboxSymbolName(for: item.state),
                    pointSize: checkboxPointSize
                )
                .foregroundColor(isCompleted ? .secondary : .primary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .safeHelp(
                isCompleted
                    ? String(localized: "sidebar.checklist.uncheckTooltip", defaultValue: "Mark as pending")
                    : String(localized: "sidebar.checklist.checkTooltip", defaultValue: "Mark as completed")
            )
            if isEditing {
                TextField(
                    String(localized: "sidebar.checklist.editItemPlaceholder", defaultValue: "Item text"),
                    text: $editingText
                )
                .textFieldStyle(.plain)
                .font(.system(size: itemFontSize))
                .foregroundColor(.primary)
                .focused(editFieldFocused)
                .onSubmit { actions.commitEdit() }
                .onExitCommand(perform: actions.cancelEdit)
                .accessibilityIdentifier("WorkspaceTodoPaneEditItemField")
            } else {
                Text(item.text)
                    .font(.system(size: itemFontSize))
                    .foregroundColor(isCompleted ? .secondary : .primary)
                    .strikethrough(isCompleted)
                    .opacity(isCompleted ? 0.6 : 1)
                    .contentShape(Rectangle())
                    .onTapGesture { actions.beginEdit() }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isHighlighted ? Color.primary.opacity(0.08) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture { actions.select() }
        // Drag to reorder within the item's completion partition; the model
        // clamps the target so completed items always stay last (item 5).
        .draggable(item.id.uuidString)
        .dropDestination(for: String.self) { payload, _ in
            actions.handleDrop(payload, displayIndex)
        }
        .contextMenu {
            Button(String(localized: "sidebar.checklist.editItem", defaultValue: "Edit")) {
                actions.beginEdit()
            }
            if item.state != .inProgress {
                Button(String(localized: "sidebar.checklist.markInProgress", defaultValue: "Mark In Progress")) {
                    actions.markInProgress()
                }
            }
            Button(String(localized: "sidebar.checklist.removeItem", defaultValue: "Remove")) {
                actions.remove()
            }
        }
        .accessibilityIdentifier("WorkspaceTodoPaneItemRow")
    }

    private func checkboxSymbolName(for state: WorkspaceChecklistItem.State) -> String {
        switch state {
        case .pending: return "square"
        case .inProgress: return "minus.square"
        case .completed: return "checkmark.square.fill"
        }
    }
}

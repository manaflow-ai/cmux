import CmuxWorkspaces
import SwiftUI

/// The value snapshot the checklist popover renders (Equatable so the
/// NSPopover host only rebuilds content when it actually changes).
struct SidebarWorkspaceChecklistPopoverModel: Equatable {
    let workspaceTitle: String
    let items: [WorkspaceChecklistItem]
    let completedCount: Int
    let totalCount: Int
    /// Bumped by the container when "Add Checklist Item…" wants the add
    /// field armed on open.
    let addFieldActivationToken: Int
}

/// The checklist popover anchored to a workspace row's summary line
/// (`sidebar.beta.workspaceTodos.checklistStyle` = `popover`): header with
/// the workspace title and progress, the ordered item rows (completed sink
/// below unchecked, clamped at 7 with an in-place "… N more"), a ghost add
/// row whose TextField commits on Enter and re-arms, and an "Open as Pane"
/// footer. Hosted in a real NSPopover so the TextField can take first
/// responder (see `SidebarWorkspaceTodoPopoverHost`).
struct SidebarWorkspaceChecklistPopover: View {
    let model: SidebarWorkspaceChecklistPopoverModel
    let actions: SidebarWorkspaceChecklistActions
    let onConsumeAddFieldActivation: () -> Void
    let onClose: @MainActor () -> Void

    @State private var showsAllItems = false
    @State private var pendingItemText = ""
    @FocusState private var addFieldFocused: Bool
    @State private var editingItemId: UUID?
    @State private var editingText = ""
    @FocusState private var editFieldFocused: Bool
    /// The keyboard-highlighted item: Up/Down from the add field moves it,
    /// Return toggles it when the add field is empty, and Cmd+Return always
    /// toggles it between completed and pending.
    @State private var highlightedItemId: UUID?

    private static let itemFontSize: CGFloat = 13
    /// Checkbox glyphs draw at 13pt (the inline row's base is 8pt·scale).
    private static let checkboxPointSize: CGFloat = 13

    var body: some View {
        let ordered = SidebarWorkspaceChecklistDisplayPolicy.orderedItems(model.items)
        let clamped = SidebarWorkspaceChecklistDisplayPolicy.clampedItems(
            ordered,
            showsAllItems: showsAllItems
        )
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 6)
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(clamped.visible) { item in
                        itemRow(item)
                    }
                    if clamped.hiddenCount > 0 {
                        moreRow(hiddenCount: clamped.hiddenCount)
                    }
                    addItemRow(visible: clamped.visible)
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 6)
            }
            .frame(maxHeight: 460)
            Divider()
            footer
        }
        .frame(width: 320, alignment: .leading)
        .background(toggleHighlightedShortcutButton(visible: clamped.visible))
        .onAppear { addFieldFocused = true }
        .onChange(of: addFieldFocused) { _, focused in
            if !focused { finishAddOnFocusLoss() }
        }
        .onChange(of: editFieldFocused) { _, focused in
            if !focused { finishItemEditOnFocusLoss() }
        }
        // The round-5 first-responder policy lets native TextFields in the
        // popover child window keep focus over the terminal-backed pane.
        // Bump-driven add activations still explicitly re-arm the add field.
        .task(id: model.addFieldActivationToken) {
            guard model.addFieldActivationToken > 0 else { return }
            addFieldFocused = true
        }
        .accessibilityIdentifier("SidebarWorkspaceChecklistPopover")
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(model.workspaceTitle)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            Text(verbatim: "\(model.completedCount)/\(model.totalCount)")
                .font(.system(size: 11).monospacedDigit())
                .foregroundColor(.secondary)
        }
    }

    // MARK: Item rows

    private func itemRow(_ item: WorkspaceChecklistItem) -> some View {
        let isCompleted = item.state == .completed
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Button {
                actions.setItemState(item.id, isCompleted ? .pending : .completed)
            } label: {
                CmuxSystemSymbolImage(
                    systemName: checkboxSymbolName(for: item.state),
                    pointSize: Self.checkboxPointSize
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
            if editingItemId == item.id {
                TextField(
                    String(localized: "sidebar.checklist.editItemPlaceholder", defaultValue: "Item text"),
                    text: $editingText
                )
                .textFieldStyle(.plain)
                .font(.system(size: Self.itemFontSize))
                .foregroundColor(.primary)
                .focused($editFieldFocused)
                .onSubmit { commitItemEdit(item.id) }
                .onExitCommand(perform: cancelItemEdit)
                .accessibilityIdentifier("SidebarChecklistPopoverEditItemField")
            } else {
                Text(item.text)
                    .font(.system(size: Self.itemFontSize))
                    .foregroundColor(isCompleted ? .secondary : .primary)
                    .strikethrough(isCompleted)
                    .opacity(isCompleted ? 0.6 : 1)
                    .lineLimit(3)
                    .truncationMode(.tail)
                    .contentShape(Rectangle())
                    .onTapGesture { beginItemEdit(item) }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(highlightedItemId == item.id ? Color.primary.opacity(0.08) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture { highlightedItemId = item.id }
        .contextMenu {
            Button(String(localized: "sidebar.checklist.editItem", defaultValue: "Edit")) {
                beginItemEdit(item)
            }
            if item.state != .inProgress {
                Button(String(localized: "sidebar.checklist.markInProgress", defaultValue: "Mark In Progress")) {
                    actions.setItemState(item.id, .inProgress)
                }
            }
            Button(String(localized: "sidebar.checklist.removeItem", defaultValue: "Remove")) {
                actions.removeItem(item.id)
            }
        }
        .accessibilityIdentifier("SidebarChecklistPopoverItemRow")
    }

    private func checkboxSymbolName(for state: WorkspaceChecklistItem.State) -> String {
        switch state {
        case .pending: return "square"
        case .inProgress: return "minus.square"
        case .completed: return "checkmark.square.fill"
        }
    }

    private func moreRow(hiddenCount: Int) -> some View {
        Button {
            showsAllItems = true
        } label: {
            Text(
                String(
                    format: String(
                        localized: "sidebar.checklist.moreItems",
                        defaultValue: "… %lld more"
                    ),
                    locale: .current,
                    hiddenCount
                )
            )
            .font(.system(size: Self.itemFontSize))
            .foregroundColor(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .accessibilityIdentifier("SidebarChecklistPopoverMoreRow")
    }

    // MARK: Add-item row (always armed — typing needs zero extra clicks)

    private func addItemRow(visible: [WorkspaceChecklistItem]) -> some View {
        let placeholder = String(
            localized: "sidebar.checklist.addItemPlaceholder",
            defaultValue: "New checklist item"
        )
        return HStack(alignment: .center, spacing: 6) {
            // A `plus.circle` "add" affordance, not an empty checkbox, so the
            // add row never reads as a real (unchecked) item.
            CmuxSystemSymbolImage(systemName: "plus.circle", pointSize: Self.checkboxPointSize)
                .foregroundColor(.secondary)
            TextField(
                placeholder,
                text: $pendingItemText
            )
            .font(.system(size: Self.itemFontSize))
            .textFieldStyle(.plain)
            .foregroundColor(.primary)
            .focused($addFieldFocused)
            .onKeyPress(.upArrow) { moveHighlight(-1, in: visible) }
            .onKeyPress(.downArrow) { moveHighlight(1, in: visible) }
            .onKeyPress(.return) { handleAddFieldReturn(visible: visible) }
            .onSubmit(commitPendingItem)
            .onExitCommand(perform: cancelPendingItem)
            .accessibilityIdentifier("SidebarChecklistPopoverAddItemField")
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
    }

    // MARK: Keyboard navigation + toggle

    /// Moves the highlight up/down through the visible items, clamping at the
    /// ends.
    private func moveHighlight(_ delta: Int, in visible: [WorkspaceChecklistItem]) -> KeyPress.Result {
        guard !visible.isEmpty else { return .ignored }
        let currentIndex = visible.firstIndex(where: { $0.id == highlightedItemId })
            ?? (delta > 0 ? -1 : visible.count)
        let next = min(max(currentIndex + delta, 0), visible.count - 1)
        highlightedItemId = visible[next].id
        return .handled
    }

    private func handleAddFieldReturn(visible: [WorkspaceChecklistItem]) -> KeyPress.Result {
        guard pendingItemText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .ignored
        }
        guard let id = highlightedItemId,
              visible.contains(where: { $0.id == id }) else { return .ignored }
        toggleHighlighted(in: visible)
        return .handled
    }

    /// A zero-size button that binds Cmd+Return to toggling the highlighted
    /// item. A `.keyboardShortcut` fires even while the add field is focused
    /// (a plain TextField only consumes bare Return via `onSubmit`), so the
    /// toggle works without stealing focus from the add field. Also exposed
    /// as the configurable `toggleChecklistItemComplete` action in Settings.
    private func toggleHighlightedShortcutButton(visible: [WorkspaceChecklistItem]) -> some View {
        Button {
            toggleHighlighted(in: visible)
        } label: { Color.clear.frame(width: 0, height: 0) }
            .buttonStyle(.plain)
            .keyboardShortcut(.return, modifiers: .command)
            .accessibilityHidden(true)
    }

    /// Return/Cmd+Return toggles the highlighted item; no-op when nothing is
    /// highlighted.
    private func toggleHighlighted(in visible: [WorkspaceChecklistItem]) {
        guard let id = highlightedItemId,
              let item = visible.first(where: { $0.id == id }) else { return }
        actions.setItemState(item.id, item.state == .completed ? .pending : .completed)
    }

    /// Enter (or focus-loss) commits the trimmed text and re-arms the field
    /// (a fresh, empty, focused add field) for the next item.
    private func commitPendingItem() {
        let text = pendingItemText
        pendingItemText = ""
        onConsumeAddFieldActivation()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        actions.addItem(text)
        addFieldFocused = true
    }

    /// Blur commits like the AppKit field's end-editing did, but never
    /// re-focuses: re-arming on blur would yank focus back from a
    /// just-started item edit (the pane's semantics; Return re-arms instead).
    private func finishAddOnFocusLoss() {
        let text = pendingItemText
        pendingItemText = ""
        onConsumeAddFieldActivation()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        actions.addItem(text)
    }

    private func cancelPendingItem() {
        pendingItemText = ""
        addFieldFocused = false
        onClose()
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
        actions.editItem(id, text)
    }

    private func finishItemEditOnFocusLoss() {
        guard let id = editingItemId else { return }
        let text = editingText
        editingItemId = nil
        editingText = ""
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        actions.editItem(id, text)
    }

    private func cancelItemEdit() {
        editingItemId = nil
        editingText = ""
        editFieldFocused = false
    }

    // MARK: Footer

    private var footer: some View {
        Button {
            actions.openPane()
            onClose()
        } label: {
            HStack(spacing: 6) {
                CmuxSystemSymbolImage(systemName: "rectangle.split.2x1", pointSize: 11)
                Text(String(localized: "sidebar.checklist.openAsPane", defaultValue: "Open as Pane"))
                    .font(.system(size: 12))
            }
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("SidebarChecklistPopoverOpenAsPane")
    }
}

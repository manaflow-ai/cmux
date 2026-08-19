import AppKit
import CmuxAppKitSupportUI
import CmuxWorkspaces
import SwiftUI

/// Top-level SwiftUI view for a ``WorkspaceTodoPanel``: a header (clickable
/// status glyph, pane title, lane name, progress) over the full
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
        ZStack(alignment: .topLeading) {
            WorkspaceTodoPanelOpaqueBackground()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Group {
                if let workspace = panel.workspace {
                    WorkspaceTodoPaneContent(
                        workspace: workspace,
                        todoState: workspace.todoState,
                        paneTitle: panel.displayTitle,
                        isFocused: isFocused,
                        addFieldArmToken: panel.addFieldArmToken
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
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .contentShape(Rectangle())
        .onTapGesture { onRequestPanelFocus() }
    }
}

enum WorkspaceTodoPaneHeaderTitle {
    nonisolated static func title(paneTitle: String) -> String {
        paneTitle
    }
}

enum WorkspaceTodoPaneHeaderStatusLabel {
    nonisolated static func displayName(
        effective: WorkspaceTaskStatus?,
        hasOverride: Bool
    ) -> String? {
        guard let effective else { return nil }
        if effective == .todo && !hasOverride { return nil }
        return effective.displayName
    }
}

enum WorkspaceTodoPaneItemRowClickPolicy {
    enum Action: Equatable {
        case select
        case beginEdit
        case focusEditor
    }

    nonisolated static func action(isEditing: Bool, isHighlighted: Bool) -> Action {
        if isEditing { return .focusEditor }
        if isHighlighted { return .beginEdit }
        return .select
    }
}

enum WorkspaceTodoPaneKeyboardNavigationPolicy {
    nonisolated static func shouldMoveHighlight(isEditing: Bool, hasItems: Bool) -> Bool {
        !isEditing && hasItems
    }
}

private struct WorkspaceTodoPanelOpaqueBackground: NSViewRepresentable {
    @Environment(\.colorScheme) private var colorScheme

    func makeNSView(context: Context) -> WorkspaceTodoPanelOpaqueBackgroundView {
        let view = WorkspaceTodoPanelOpaqueBackgroundView()
        view.colorScheme = colorScheme
        view.appearance = WindowAppearanceSnapshot.appKitAppearance(for: colorScheme)
        return view
    }

    func updateNSView(_ nsView: WorkspaceTodoPanelOpaqueBackgroundView, context: Context) {
        nsView.colorScheme = colorScheme
        nsView.needsDisplay = true
    }
}

private final class WorkspaceTodoPanelOpaqueBackgroundView: NSView {
    var colorScheme: ColorScheme = .light {
        didSet {
            guard colorScheme != oldValue else { return }
            appearance = WindowAppearanceSnapshot.appKitAppearance(for: colorScheme)
            needsDisplay = true
        }
    }

    override var isOpaque: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        WindowAppearanceSnapshot.resolvedColor(.windowBackgroundColor, for: colorScheme).setFill()
        dirtyRect.fill()
    }
}

/// The pane body once the workspace is resolved. Observes the workspace (for
/// inferred-status recomputes) and its todo state (for override and checklist
/// churn) directly.
private struct WorkspaceTodoPaneContent: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var todoState: WorkspaceTodoState
    let paneTitle: String
    let isFocused: Bool
    /// Open-or-focus bump; re-arms the add field when `isFocused` doesn't transition.
    let addFieldArmToken: Int

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
    @State private var prefixChordBridge = PrefixChordChecklistActionRegistry.Bridge()

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
        let todoControlsEnabled = WorkspaceTodoFeature.isEnabled
        let hasOverride = todoControlsEnabled && todoState.statusOverride != nil && !resolution.shouldClearOverride
        let progress = todoState.checklist.checklistProgressSummary
        let headerTitle = WorkspaceTodoPaneHeaderTitle.title(paneTitle: paneTitle)
        let headerStatusLabel = WorkspaceTodoPaneHeaderStatusLabel.displayName(
            effective: todoControlsEnabled ? resolution.effective : nil,
            hasOverride: hasOverride
        )

        VStack(alignment: .leading, spacing: 0) {
            header(
                title: headerTitle,
                effective: todoControlsEnabled ? resolution.effective : nil,
                inferred: inferred,
                hasOverride: hasOverride,
                statusLabel: headerStatusLabel,
                progress: progress
            )
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            Divider()
            let ordered = SidebarWorkspaceChecklistDisplayPolicy.orderedItems(todoState.checklist)
            ScrollViewReader { proxy in
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
                                .id(item.id)
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
                // `anchor: nil` scrolls the minimal distance needed to bring
                // the highlighted row fully into view — a no-op if it's
                // already visible.
                .onChange(of: highlightedItemId) { _, newValue in
                    guard let newValue else { return }
                    proxy.scrollTo(newValue, anchor: nil)
                }
            }
            Divider()
            if todoControlsEnabled {
                addItemRow
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
            }
        }
        // The add field is armed whenever the pane holds focus, so typing a
        // new item needs zero extra clicks after `cmux todo open`.
        .onAppear { if todoControlsEnabled, isFocused { addFieldFocused = true } }
        .onChange(of: isFocused) { _, focused in
            if todoControlsEnabled, focused, editingItemId == nil { addFieldFocused = true }
        }
        .onChange(of: addFieldArmToken) { _, _ in
            if todoControlsEnabled, editingItemId == nil { addFieldFocused = true }
        }
        .onChange(of: editFieldFocused) { _, focused in
            if !focused { finishItemEditOnFocusLoss() }
        }
        .prefixChordChecklistAction(
            bridge: prefixChordBridge,
            isEligible: { isFocused && editingItemId == nil && !ordered.isEmpty },
            perform: {
                guard let target = PrefixChordChecklistToggleTarget(
                    items: ordered,
                    highlightedItemID: highlightedItemId,
                    isEligible: isFocused && editingItemId == nil
                ) else { return false }
                WorkspaceTodoActions.setChecklistItemState(
                    id: target.itemID,
                    state: target.nextState,
                    in: workspace
                )
                return true
            }
        )
        .accessibilityIdentifier("WorkspaceTodoPane")
    }

    // MARK: Header

    private func header(
        title: String,
        effective: WorkspaceTaskStatus?,
        inferred: WorkspaceTaskStatus,
        hasOverride: Bool,
        statusLabel: String?,
        progress: WorkspaceChecklistProgressSummary
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let effective {
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
            }
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
            if let statusLabel {
                Text(statusLabel)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
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
                focusEditor: {
                    editFieldFocused = true
                },
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
                addAttachments: {
                    WorkspaceTodoActions.addImageAttachments(to: item.id, in: workspace)
                },
                removeAttachment: { attachmentId in
                    WorkspaceTodoActions.removeImageAttachment(
                        itemId: item.id,
                        attachmentId: attachmentId,
                        from: workspace
                    )
                },
                openAttachments: { selectedAttachmentId in
                    WorkspaceTodoActions.openImageAttachments(
                        item.attachments,
                        selectedAttachmentId: selectedAttachmentId
                    )
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
        guard WorkspaceTodoPaneKeyboardNavigationPolicy.shouldMoveHighlight(
            isEditing: editingItemId != nil,
            hasItems: !ordered.isEmpty
        ) else { return .ignored }
        let currentIndex = ordered.firstIndex(where: { $0.id == highlightedItemId })
            ?? (delta > 0 ? -1 : ordered.count)
        let next = min(max(currentIndex + delta, 0), ordered.count - 1)
        highlightedItemId = ordered[next].id
        return .handled
    }

    /// Return or the configured shortcut toggles the highlighted item between completed and pending.
    /// The action is also registered as the `toggleChecklistItemComplete`
    /// shortcut for Settings discoverability and rebinding; the pane handles
    /// the keystroke locally because the toggle needs the view-local highlight.
    private func handleItemsKeyPress(
        _ press: KeyPress,
        ordered: [WorkspaceChecklistItem]
    ) -> KeyPress.Result {
        if editingItemId != nil {
            return .ignored
        }
        let isPlainReturn = press.key == .return && press.modifiers.isEmpty
        guard isPlainReturn || toggleChecklistItemCompleteShortcutMatches(press) else {
            return .ignored
        }
        guard let target = PrefixChordChecklistToggleTarget(
            items: ordered,
            highlightedItemID: highlightedItemId,
            isEligible: true
        ) else { return .ignored }
        WorkspaceTodoActions.setChecklistItemState(
            id: target.itemID,
            state: target.nextState,
            in: workspace
        )
        return .handled
    }

    private func toggleChecklistItemCompleteShortcutMatches(_ press: KeyPress) -> Bool {
        let shortcut = KeyboardShortcutSettings.shortcut(for: .toggleChecklistItemComplete)
        guard let key = shortcut.keyEquivalent else { return false }
        return press.key == key && press.modifiers == shortcut.eventModifiers
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
                text: $pendingItemText,
                axis: .vertical
            )
            .font(.system(size: Self.itemFontSize))
            .textFieldStyle(.plain)
            .foregroundColor(.primary)
            .focused($addFieldFocused)
            .lineLimit(1...8)
            .fixedSize(horizontal: false, vertical: true)
            .backport.onKeyPress(.return) { modifiers in
                if modifiers.contains(.shift), modifiers.subtracting(.shift).isEmpty {
                    pendingItemText.append("\n")
                    return .handled
                }
                return .ignored
            }
            .onSubmit(commitPendingItem)
            .onExitCommand(perform: cancelPendingItem)
            .accessibilityIdentifier("WorkspaceTodoPaneAddItemField")
        }
    }

    /// Enter commits the trimmed text and re-arms the field for the next item.
    private func commitPendingItem() {
        guard WorkspaceTodoFeature.isEnabled else { return }
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

    /// Cmd-Return or focus loss commits the trimmed replacement text; empty keeps the old text.
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

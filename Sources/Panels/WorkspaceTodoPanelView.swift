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
                    todoState: workspace.todoState
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

    @State private var isStatusPopoverPresented = false
    @State private var isAddingItem = false
    @State private var pendingItemText = ""
    @FocusState private var addFieldFocused: Bool

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
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 3) {
                    let ordered = SidebarWorkspaceChecklistDisplayPolicy.orderedItems(todoState.checklist)
                    if ordered.isEmpty {
                        Text(String(
                            localized: "workspaceTodoPane.emptyChecklist",
                            defaultValue: "No checklist items yet."
                        ))
                        .font(.system(size: Self.itemFontSize))
                        .foregroundColor(.secondary)
                        .padding(.vertical, 4)
                    }
                    ForEach(ordered) { item in
                        itemRow(item)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            addItemRow
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
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

    private func itemRow(_ item: WorkspaceChecklistItem) -> some View {
        let isCompleted = item.state == .completed
        return HStack(alignment: .firstTextBaseline, spacing: 7) {
            Button {
                WorkspaceTodoActions.setChecklistItemState(
                    id: item.id,
                    state: isCompleted ? .pending : .completed,
                    in: workspace
                )
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
            Text(item.text)
                .font(.system(size: Self.itemFontSize))
                .foregroundColor(isCompleted ? .secondary : .primary)
                .strikethrough(isCompleted)
                .opacity(isCompleted ? 0.6 : 1)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 1)
        .contextMenu {
            if item.state != .inProgress {
                Button(String(localized: "sidebar.checklist.markInProgress", defaultValue: "Mark In Progress")) {
                    WorkspaceTodoActions.setChecklistItemState(id: item.id, state: .inProgress, in: workspace)
                }
            }
            Button(String(localized: "sidebar.checklist.removeItem", defaultValue: "Remove")) {
                WorkspaceTodoActions.removeChecklistItem(id: item.id, from: workspace)
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

    // MARK: Add-item row (pinned at the bottom)

    @ViewBuilder
    private var addItemRow: some View {
        if isAddingItem {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                CmuxSystemSymbolImage(systemName: "square", pointSize: Self.checkboxPointSize)
                    .foregroundColor(.secondary)
                TextField(
                    String(localized: "sidebar.checklist.addItemPlaceholder", defaultValue: "New checklist item"),
                    text: $pendingItemText
                )
                .textFieldStyle(.plain)
                .font(.system(size: Self.itemFontSize))
                .foregroundColor(.primary)
                .focused($addFieldFocused)
                .onSubmit(commitPendingItem)
                .onExitCommand(perform: cancelPendingItem)
                .accessibilityIdentifier("WorkspaceTodoPaneAddItemField")
            }
        } else {
            Button {
                isAddingItem = true
                addFieldFocused = true
            } label: {
                HStack(spacing: 7) {
                    CmuxSystemSymbolImage(systemName: "plus", pointSize: 11)
                    Text(String(localized: "sidebar.checklist.addItem", defaultValue: "Add item"))
                        .font(.system(size: Self.itemFontSize))
                }
                .foregroundColor(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("WorkspaceTodoPaneAddItemRow")
        }
    }

    /// Enter commits the trimmed text and re-arms the field for the next item.
    private func commitPendingItem() {
        let text = pendingItemText
        pendingItemText = ""
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            cancelPendingItem()
            return
        }
        WorkspaceTodoActions.addChecklistItem(text: text, to: workspace)
        addFieldFocused = true
    }

    /// Esc dismisses the field without committing.
    private func cancelPendingItem() {
        pendingItemText = ""
        isAddingItem = false
        addFieldFocused = false
    }
}

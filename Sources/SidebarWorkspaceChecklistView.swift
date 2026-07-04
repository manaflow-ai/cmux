import CmuxWorkspaces
import SwiftUI

// MARK: - Display policy

/// Pure display ordering/clamping for the sidebar checklist. Kept free of
/// SwiftUI so it is unit-testable.
enum SidebarWorkspaceChecklistDisplayPolicy {
    /// How many items the expanded list shows before collapsing the rest
    /// behind a "… N more" row.
    static let visibleItemLimit = 7

    /// Completed items sink below unchecked ones; order is otherwise stable.
    static func orderedItems(_ items: [WorkspaceChecklistItem]) -> [WorkspaceChecklistItem] {
        items.filter { $0.state != .completed } + items.filter { $0.state == .completed }
    }

    /// Clamps the ordered list at ``visibleItemLimit`` unless fully expanded.
    static func clampedItems(
        _ orderedItems: [WorkspaceChecklistItem],
        showsAllItems: Bool
    ) -> (visible: [WorkspaceChecklistItem], hiddenCount: Int) {
        guard !showsAllItems, orderedItems.count > visibleItemLimit else {
            return (orderedItems, 0)
        }
        return (
            Array(orderedItems.prefix(visibleItemLimit)),
            orderedItems.count - visibleItemLimit
        )
    }
}

// MARK: - Actions bundle

/// Closure bundle the row passes below the snapshot boundary (rows receive
/// immutable value snapshots plus action closures only; see the
/// snapshot-boundary rule in CLAUDE.md).
struct SidebarWorkspaceChecklistActions {
    let setItemState: @MainActor (UUID, WorkspaceChecklistItem.State) -> Void
    let removeItem: @MainActor (UUID) -> Void
    let addItem: @MainActor (String) -> Void
    /// Rewrites one item's text (tap-to-edit).
    let editItem: @MainActor (UUID, String) -> Void
    /// Opens the workspace's todo pane (checklist popover footer).
    let openPane: @MainActor () -> Void
}

// MARK: - Section (summary line + optional expansion)

/// The checklist block under a workspace row's detail lines: a one-line
/// progress summary that toggles an inline expansion listing the items, with
/// a trailing ghost "Add item" row. All inputs are value snapshots; height
/// changes apply in one discrete layout pass (no animation — lazy rows must
/// stay height-stable, see #5764/#5845).
struct SidebarWorkspaceChecklistSection: View {
    let items: [WorkspaceChecklistItem]
    let completedCount: Int
    let totalCount: Int
    let firstUncheckedText: String?
    /// The workspace title, shown in the checklist popover's header.
    let workspaceTitle: String
    let isExpanded: Bool
    /// Incremented by the sidebar container when a context-menu/palette
    /// "Add Checklist Item…" asks this row to arm and focus its add field.
    let addFieldActivationToken: Int
    /// Whether the `sidebar.beta.workspaceTodos.checklistStyle` setting is
    /// `popover`: the summary line opens an anchored checklist popover
    /// instead of the inline expansion. Empty checklists keep the inline
    /// ghost add row either way (no summary line to anchor to).
    let usesPopoverPresentation: Bool
    let isPopoverPresented: Bool
    let primaryColor: Color
    let secondaryColor: Color
    let summaryFont: Font
    let itemFont: Font
    let fontScale: CGFloat
    let onToggleExpansion: () -> Void
    let onPopoverPresentedChange: @MainActor (Bool) -> Void
    let onConsumeAddFieldActivation: () -> Void
    let actions: SidebarWorkspaceChecklistActions

    @State private var showsAllItems = false
    @State private var isAddingItem = false
    @State private var pendingItemText = ""
    @FocusState private var addFieldFocused: Bool
    @State private var editingItemId: UUID?
    @State private var editingText = ""
    @FocusState private var editFieldFocused: Bool

    /// Popover presentation only applies once a summary line exists.
    private var presentsPopover: Bool {
        usesPopoverPresentation && totalCount > 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if totalCount > 0 {
                summaryLine
            }
            if (isExpanded && !presentsPopover) || totalCount == 0 {
                expandedList
            }
        }
        .task(id: addFieldActivationToken) {
            // In popover presentation the container routes the token into the
            // checklist popover instead; arming the (hidden) inline field
            // here would fight the popover's own add field for focus.
            guard addFieldActivationToken > 0, !presentsPopover else { return }
            isAddingItem = true
            addFieldFocused = true
        }
    }

    // MARK: Summary line

    private var summaryLine: some View {
        Button(action: {
            if presentsPopover {
                onPopoverPresentedChange(!isPopoverPresented)
            } else {
                onToggleExpansion()
            }
        }) {
            HStack(spacing: 4) {
                CmuxSystemSymbolImage(
                    magnified: completedCount == totalCount ? "checkmark.circle.fill" : "checklist",
                    pointSize: 8 * fontScale
                )
                .foregroundColor(secondaryColor)
                Text(verbatim: "\(completedCount)/\(totalCount)")
                    .font(summaryFont)
                    .foregroundColor(primaryColor)
                if let firstUncheckedText {
                    Text(verbatim: "·")
                        .font(summaryFont)
                        .foregroundColor(secondaryColor)
                    Text(firstUncheckedText)
                        .font(itemFont)
                        .foregroundColor(secondaryColor)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .safeHelp(
            presentsPopover
                ? String(localized: "sidebar.checklist.popoverTooltip", defaultValue: "Show checklist")
                : (isExpanded
                    ? String(localized: "sidebar.checklist.collapseTooltip", defaultValue: "Hide checklist items")
                    : String(localized: "sidebar.checklist.expandTooltip", defaultValue: "Show checklist items"))
        )
        .modifier(ChecklistSummaryPopoverModifier(
            isPresented: presentsPopover
                ? Binding(get: { isPopoverPresented }, set: { onPopoverPresentedChange($0) })
                : .constant(false),
            model: SidebarWorkspaceChecklistPopoverModel(
                workspaceTitle: workspaceTitle,
                items: items,
                completedCount: completedCount,
                totalCount: totalCount,
                addFieldActivationToken: addFieldActivationToken
            ),
            actions: actions,
            onConsumeAddFieldActivation: onConsumeAddFieldActivation,
            onPopoverPresentedChange: onPopoverPresentedChange
        ))
        .accessibilityIdentifier("SidebarChecklistSummaryLine")
    }

    // MARK: Expanded list

    @ViewBuilder
    private var expandedList: some View {
        let ordered = SidebarWorkspaceChecklistDisplayPolicy.orderedItems(items)
        let clamped = SidebarWorkspaceChecklistDisplayPolicy.clampedItems(
            ordered,
            showsAllItems: showsAllItems
        )
        VStack(alignment: .leading, spacing: 2) {
            ForEach(clamped.visible) { item in
                checklistItemRow(item)
            }
            if clamped.hiddenCount > 0 {
                moreRow(hiddenCount: clamped.hiddenCount)
            }
            addItemRow
        }
        .padding(.leading, 2)
    }

    private func checklistItemRow(_ item: WorkspaceChecklistItem) -> some View {
        let isCompleted = item.state == .completed
        return HStack(alignment: .firstTextBaseline, spacing: 4) {
            Button {
                actions.setItemState(item.id, isCompleted ? .pending : .completed)
            } label: {
                CmuxSystemSymbolImage(
                    magnified: checkboxSymbolName(for: item.state),
                    pointSize: 8 * fontScale
                )
                .foregroundColor(isCompleted ? secondaryColor : primaryColor)
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
                .font(itemFont)
                .foregroundColor(primaryColor)
                .focused($editFieldFocused)
                .onSubmit { commitItemEdit(item.id) }
                .onExitCommand(perform: cancelItemEdit)
                .accessibilityIdentifier("SidebarChecklistEditItemField")
            } else {
                Text(item.text)
                    .font(itemFont)
                    .foregroundColor(isCompleted ? secondaryColor : primaryColor)
                    .strikethrough(isCompleted)
                    .opacity(isCompleted ? 0.6 : 1)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .contentShape(Rectangle())
                    .onTapGesture { beginItemEdit(item) }
            }
            Spacer(minLength: 0)
        }
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
        .accessibilityIdentifier("SidebarChecklistItemRow")
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
            .font(itemFont)
            .foregroundColor(secondaryColor)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("SidebarChecklistMoreRow")
    }

    // MARK: Add-item row

    @ViewBuilder
    private var addItemRow: some View {
        if isAddingItem {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                CmuxSystemSymbolImage(magnified: "square", pointSize: 8 * fontScale)
                    .foregroundColor(secondaryColor)
                TextField(
                    String(localized: "sidebar.checklist.addItemPlaceholder", defaultValue: "New checklist item"),
                    text: $pendingItemText
                )
                .textFieldStyle(.plain)
                .font(itemFont)
                .foregroundColor(primaryColor)
                .focused($addFieldFocused)
                .onSubmit(commitPendingItem)
                .onExitCommand(perform: cancelPendingItem)
                .accessibilityIdentifier("SidebarChecklistAddItemField")
            }
        } else {
            Button {
                isAddingItem = true
                addFieldFocused = true
            } label: {
                HStack(spacing: 4) {
                    CmuxSystemSymbolImage(magnified: "plus", pointSize: 7 * fontScale)
                    Text(String(localized: "sidebar.checklist.addItem", defaultValue: "Add item"))
                        .font(itemFont)
                }
                .foregroundColor(secondaryColor)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("SidebarChecklistAddItemRow")
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
        actions.addItem(text)
        addFieldFocused = true
    }

    /// Esc dismisses the field without committing.
    private func cancelPendingItem() {
        pendingItemText = ""
        isAddingItem = false
        addFieldFocused = false
        onConsumeAddFieldActivation()
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

    private func cancelItemEdit() {
        editingItemId = nil
        editingText = ""
        editFieldFocused = false
    }
}

/// Attaches the checklist popover to the summary line with SwiftUI's native
/// `.popover` (not the NSPopover host): an embedded NSViewRepresentable inside
/// a `.onHover`-tracked sidebar row suppresses the row's hover tracking, which
/// hid the hover-close "x". The add field takes first responder via
/// `@FocusState` set on appear inside `SidebarWorkspaceChecklistPopover`.
private struct ChecklistSummaryPopoverModifier: ViewModifier {
    @Binding var isPresented: Bool
    let model: SidebarWorkspaceChecklistPopoverModel
    let actions: SidebarWorkspaceChecklistActions
    let onConsumeAddFieldActivation: () -> Void
    let onPopoverPresentedChange: @MainActor (Bool) -> Void

    func body(content: Content) -> some View {
        content.popover(isPresented: $isPresented, arrowEdge: .trailing) {
            SidebarWorkspaceChecklistPopover(
                model: model,
                actions: actions,
                onConsumeAddFieldActivation: onConsumeAddFieldActivation,
                onClose: { onPopoverPresentedChange(false) }
            )
            .frame(width: 320)
        }
    }
}

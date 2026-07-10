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
    /// Moves one item toward a new 0-based position (within its completion
    /// partition; used by the todo pane's drag reorder).
    let moveItem: @MainActor (UUID, Int) -> Void
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
    /// `popover`: the summary line (or, for an empty checklist with no
    /// summary line yet, the ghost "Add item" row) opens an anchored
    /// checklist popover instead of the inline expansion — including for a
    /// workspace's very first item.
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
    /// Bumped after each add to recreate the AppKit add field (which re-focuses
    /// and clears itself on appear).
    @State private var inlineAddGeneration = 0
    @State private var editingItemId: UUID?
    /// The item currently under the pointer, used to reveal the trailing
    /// delete button. A single id (not a per-row `@State`) is enough because
    /// only one row can be hovered at a time; mirrors `editingItemId`.
    @State private var hoveredItemId: UUID?

    /// Whether taps and the "Add Checklist Item…" activation token should
    /// route to the anchored popover instead of the inline expansion. Equal
    /// to `usesPopoverPresentation` regardless of `totalCount`, so a
    /// workspace's very first checklist item also opens the popover in
    /// `.popover` style — the popover anchor lives on the outer container
    /// below, which is present whether or not a summary line exists yet.
    private var presentsPopover: Bool {
        usesPopoverPresentation
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
        // The popover anchor is hosted here (not on `summaryLine` alone) so
        // the same backing NSView anchors the popover across the 0→1 item
        // transition, when `summaryLine` first appears and `expandedList`
        // (which holds the ghost "Add item" row for an empty checklist)
        // disappears — re-anchoring to a freshly created view would close
        // and immediately reopen the popover.
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
        .task(id: addFieldActivationToken) {
            // In popover presentation the container routes the token into the
            // checklist popover instead; arming the (hidden) inline field
            // here would fight the popover's own add field for focus.
            guard addFieldActivationToken > 0, !presentsPopover else { return }
            isAddingItem = true
            inlineAddGeneration += 1
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
                ChecklistInputField(
                    initialText: item.text,
                    placeholder: String(localized: "sidebar.checklist.editItemPlaceholder", defaultValue: "Item text"),
                    fontSize: 11 * fontScale,
                    onCommit: { commitItemEdit(item.id, text: $0) },
                    onCancel: cancelItemEdit,
                    selectsAllOnFocus: true,
                    textColor: NSColor(primaryColor)
                )
                .frame(height: 11 * fontScale + 4)
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
            removeItemButton(for: item)
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            if hovering {
                hoveredItemId = item.id
            } else if hoveredItemId == item.id {
                hoveredItemId = nil
            }
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

    /// Trailing hover-reveal delete affordance, in addition to the row's
    /// context-menu "Remove" entry. Always laid out at a fixed size (only
    /// `.opacity`/`.allowsHitTesting` toggle) so the row's height never jumps
    /// when the pointer enters/leaves — same reserved-space technique as the
    /// workspace row's hover close button (`SidebarWorkspaceTrailingStatusSlot`).
    private func removeItemButton(for item: WorkspaceChecklistItem) -> some View {
        let isHovered = hoveredItemId == item.id
        return Button {
            actions.removeItem(item.id)
        } label: {
            CmuxSystemSymbolImage(magnified: "xmark.circle.fill", pointSize: 9 * fontScale)
                .foregroundColor(secondaryColor)
                .frame(width: 9 * fontScale + 8, height: 9 * fontScale + 8, alignment: .center)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .safeHelp(String(localized: "sidebar.checklist.removeItemTooltip", defaultValue: "Remove item"))
        .opacity(isHovered ? 1 : 0)
        .allowsHitTesting(isHovered)
        .accessibilityHidden(!isHovered)
        .accessibilityIdentifier("SidebarChecklistRemoveItemButton")
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
                // A `plus.circle` "add" affordance, not an empty checkbox, so
                // the add row never reads as a real (unchecked) item. Uses the
                // row's secondary color (which inverts on the selected row) so
                // it never clashes as accent-blue on a blue selected row.
                CmuxSystemSymbolImage(magnified: "plus.circle", pointSize: 8 * fontScale)
                    .foregroundColor(secondaryColor)
                // AppKit field (like the sidebar rename field): takes first
                // responder in the main window on appear, so typing works
                // reliably (a SwiftUI TextField / floating popover does not win
                // focus from the terminal).
                ChecklistInputField(
                    initialText: "",
                    placeholder: String(localized: "sidebar.checklist.addItemPlaceholder", defaultValue: "New checklist item"),
                    fontSize: 11 * fontScale,
                    onCommit: { commitInlineAdd($0) },
                    onCancel: cancelPendingItem,
                    textColor: NSColor(primaryColor)
                )
                .id(inlineAddGeneration)
                .frame(height: 11 * fontScale + 4)
                .accessibilityIdentifier("SidebarChecklistAddItemField")
            }
        } else {
            Button {
                if presentsPopover {
                    onPopoverPresentedChange(!isPopoverPresented)
                } else {
                    isAddingItem = true
                }
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

    /// Enter (or focus-loss) commits the trimmed text and re-arms the field
    /// (a fresh, focused, empty add field) for the next item.
    private func commitInlineAdd(_ text: String) {
        inlineAddGeneration += 1
        onConsumeAddFieldActivation()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        actions.addItem(text)
    }

    /// Esc dismisses the add field.
    private func cancelPendingItem() {
        isAddingItem = false
        onConsumeAddFieldActivation()
    }

    // MARK: Item text editing

    private func beginItemEdit(_ item: WorkspaceChecklistItem) {
        editingItemId = item.id
    }

    /// Enter commits the trimmed replacement text; empty keeps the old text.
    private func commitItemEdit(_ id: UUID, text: String) {
        cancelItemEdit()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        actions.editItem(id, text)
    }

    private func cancelItemEdit() {
        editingItemId = nil
    }
}

/// Attaches the checklist popover to the section container (not just the
/// summary line — see the call site comment in ``SidebarWorkspaceChecklistSection/body``)
/// with SwiftUI's native `.popover` (not the NSPopover host): an embedded
/// NSViewRepresentable inside a `.onHover`-tracked sidebar row suppresses the
/// row's hover tracking, which hid the hover-close "x". The add field takes
/// first responder via `@FocusState` set on appear inside
/// `SidebarWorkspaceChecklistPopover`.
private struct ChecklistSummaryPopoverModifier: ViewModifier {
    @Binding var isPresented: Bool
    let model: SidebarWorkspaceChecklistPopoverModel
    let actions: SidebarWorkspaceChecklistActions
    let onConsumeAddFieldActivation: () -> Void
    let onPopoverPresentedChange: @MainActor (Bool) -> Void

    // The checklist popover embeds a first-responder TextField (the add / edit
    // fields). SwiftUI's native `.popover` does not make its window key in
    // cmux's focus-managed environment, so keystrokes fall through to the
    // terminal. Host it in a real NSPopover (which takes key) instead. This
    // modifier is only attached within the checklist section, so it does not
    // touch the every-row hover path the status glyph uses.
    func body(content: Content) -> some View {
        content.background(
            SidebarWorkspaceTodoPopoverHost(
                isPresented: $isPresented,
                model: model,
                minWidth: 320,
                maxHeight: 520,
                preferredEdge: .maxX
            ) { model, close in
                SidebarWorkspaceChecklistPopover(
                    model: model,
                    actions: actions,
                    onConsumeAddFieldActivation: onConsumeAddFieldActivation,
                    onClose: {
                        close()
                        onPopoverPresentedChange(false)
                    }
                )
            }
        )
    }
}

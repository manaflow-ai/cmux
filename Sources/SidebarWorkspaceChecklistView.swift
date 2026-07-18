import AppKit
import CmuxWorkspaces
import SwiftUI

// MARK: - Minimal visibility policy

/// Pure mount/compact policy for todo affordances in compact sidebar rows.
/// Checklist content must stay mounted while it is visible or anchoring an
/// open/add-requested popover; status stays visible only when the row is in
/// compact detail mode and the workspace has opted into status display.
struct SidebarWorkspaceTodoMinimalVisibility: Equatable {
    let itemCount: Int
    let addFieldActivationToken: Int
    let isPopoverPresented: Bool
    let canAddItems: Bool
    let hidesAllDetails: Bool
    let taskStatus: WorkspaceTaskStatus?
    let featureEnabled: Bool

    var showsChecklistSection: Bool {
        itemCount > 0 || (canAddItems && (addFieldActivationToken > 0 || isPopoverPresented))
    }

    var showsCompactStatus: Bool {
        featureEnabled && hidesAllDetails && taskStatus != nil
    }
}

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
    /// Opens an image picker and attaches selected images to one item.
    let addAttachments: @MainActor (UUID) -> Void
    /// Removes one attachment reference from one item.
    let removeAttachment: @MainActor (UUID, UUID) -> Void
    /// Opens one item's attachments in Quick Look.
    let openAttachments: @MainActor (UUID, UUID?) -> Void
}

// MARK: - Attachment menu

struct WorkspaceChecklistAttachmentMenu: View {
    let item: WorkspaceChecklistItem
    let iconPointSize: CGFloat
    let foregroundColor: Color
    let countFont: Font
    let addAttachments: @MainActor (UUID) -> Void
    let removeAttachment: @MainActor (UUID, UUID) -> Void
    let openAttachments: @MainActor (UUID, UUID?) -> Void

    var body: some View {
        Menu {
            Button(String(localized: "sidebar.checklist.attachImages", defaultValue: "Attach Images…")) {
                addAttachments(item.id)
            }
            if !item.attachments.isEmpty {
                Divider()
                ForEach(item.attachments) { attachment in
                    Menu(attachment.displayName) {
                        Button(String(localized: "sidebar.checklist.openAttachment", defaultValue: "Open")) {
                            openAttachments(item.id, attachment.id)
                        }
                        Button(String(
                            localized: "sidebar.checklist.removeAttachment",
                            defaultValue: "Remove Attachment"
                        )) {
                            removeAttachment(item.id, attachment.id)
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 2) {
                CmuxSystemSymbolImage(systemName: "paperclip", pointSize: iconPointSize)
                if item.attachmentCount > 0 {
                    Text(verbatim: "\(item.attachmentCount)")
                        .font(countFont)
                        .monospacedDigit()
                }
            }
            .foregroundColor(foregroundColor)
            .frame(minWidth: iconPointSize + 8, minHeight: iconPointSize + 8, alignment: .center)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .safeHelp(String(localized: "sidebar.checklist.attachmentsTooltip", defaultValue: "Manage images"))
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier("WorkspaceChecklistAttachmentMenu")
    }

    private var accessibilityLabel: String {
        switch item.attachmentCount {
        case 0:
            return String(
                localized: "sidebar.checklist.attachments.noneAccessibility",
                defaultValue: "No images attached. Attach images."
            )
        case 1:
            return String(localized: "sidebar.checklist.attachments.one", defaultValue: "1 image attached")
        default:
            return String.localizedStringWithFormat(
                String(
                    localized: "sidebar.checklist.attachments.other",
                    defaultValue: "%lld images attached"
                ),
                Int64(item.attachmentCount)
            )
        }
    }
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
    /// Whether add-item entry points are exposed by the remote controls flag.
    let canAddItems: Bool
    let onToggleExpansion: () -> Void
    let onPopoverPresentedChange: @MainActor (Bool) -> Void
    let onConsumeAddFieldActivation: () -> Void
    let actions: SidebarWorkspaceChecklistActions

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
            // In popover style, "Add Checklist Item…" opens the popover
            // directly (see the container's `.workspaceChecklistAddItemRequested`
            // handler) — the row itself shows nothing inline (no ghost
            // "Add item" affordance) until an item actually exists, at
            // which point `summaryLine` above is the small status preview.
            if !presentsPopover, isExpanded || totalCount == 0 {
                expandedList
            }
        }
        // The popover anchor is hosted here (not on `summaryLine` alone) so
        // the same backing NSView anchors the popover across the 0→1 item
        // transition — this outer container is always present (even when
        // popover style renders neither `summaryLine` nor `expandedList`
        // while `totalCount == 0`), so the anchor never needs to move;
        // re-anchoring to a freshly created view would close and immediately
        // reopen the popover. The anchor is a fixed 1×1pt corner overlay
        // (see `ChecklistSummaryPopoverModifier`), so it has real, stable
        // bounds regardless of whether this VStack has any content.
        .modifier(ChecklistSummaryPopoverModifier(
            isPresented: presentsPopover
                ? Binding(get: { isPopoverPresented }, set: { presented in
                    onPopoverPresentedChange(presented)
                    // Any close consumes a pending add-field activation: a
                    // dismissed first-item popover must not leave the
                    // workspace in stale "add requested" state (which also
                    // keeps the empty section mounted invisibly).
                    if !presented { onConsumeAddFieldActivation() }
                })
                : .constant(false),
            model: SidebarWorkspaceChecklistPopoverModel(
                workspaceTitle: workspaceTitle,
                items: items,
                completedCount: completedCount,
                totalCount: totalCount,
                addFieldActivationToken: addFieldActivationToken,
                canAddItems: canAddItems
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
            guard canAddItems else { return }
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
        VStack(alignment: .leading, spacing: 2) {
            if !ordered.isEmpty {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(ordered) { item in
                            checklistItemRow(item)
                        }
                    }
                }
                .frame(height: scrollViewportHeight(forItemCount: ordered.count))
            }
            if canAddItems {
                addItemRow
            }
        }
        .padding(.leading, 2)
    }

    /// Single-line row height estimate (matches the add/edit field's own
    /// `11 * fontScale + 4` sizing), used to cap the expanded list's
    /// scrollable viewport at ``visibleRowCount`` rows instead of letting an
    /// arbitrarily long checklist grow the sidebar row without bound.
    private var itemRowHeightEstimate: CGFloat { 11 * fontScale + 4 }
    private static let visibleRowCount = 6
    private static let rowSpacing: CGFloat = 2

    /// Content height for `count` rows, capped at ``visibleRowCount`` rows —
    /// short lists get exactly their own height (no dead space), longer
    /// lists get the 6-row cap and scroll for the rest.
    private func scrollViewportHeight(forItemCount count: Int) -> CGFloat {
        guard count > 0 else { return 0 }
        let visibleCount = min(count, Self.visibleRowCount)
        return itemRowHeightEstimate * CGFloat(visibleCount)
            + Self.rowSpacing * CGFloat(visibleCount - 1)
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
            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + firstLineCenterOffset }
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
                // No `lineLimit` — items wrap across multiple lines. The
                // checkbox/remove button above/below align to this Text's
                // FIRST line only (`.firstTextBaseline`, offset by
                // `firstLineCenterOffset`), not the whole wrapped block.
                Text(item.text)
                    .font(itemFont)
                    .foregroundColor(isCompleted ? secondaryColor : primaryColor)
                    .strikethrough(isCompleted)
                    .opacity(isCompleted ? 0.6 : 1)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentShape(Rectangle())
                    .onTapGesture { beginItemEdit(item) }
            }
            Spacer(minLength: 0)
            WorkspaceChecklistAttachmentMenu(
                item: item,
                iconPointSize: 9 * fontScale,
                foregroundColor: secondaryColor,
                countFont: itemFont,
                addAttachments: actions.addAttachments,
                removeAttachment: actions.removeAttachment,
                openAttachments: actions.openAttachments
            )
            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + firstLineCenterOffset }
            removeItemButton(for: item)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + firstLineCenterOffset }
        }
        .contentShape(Rectangle())
        // `.onContinuousHover` rather than `.onHover`: `.onHover` only fires
        // on the `mouseEntered`/`mouseExited` edge, so if this row's backing
        // view gets recreated (e.g. a sidebar re-render under this section)
        // while the pointer is already inside it, no new `mouseEntered`
        // arrives and the hover state gets stuck off — the "barely or never
        // appears" symptom. Continuous hover re-derives the phase from the
        // current pointer location on every move, so it self-corrects within
        // one frame regardless of view-identity churn.
        .onContinuousHover { phase in
            switch phase {
            case .active:
                hoveredItemId = item.id
            case .ended:
                if hoveredItemId == item.id {
                    hoveredItemId = nil
                }
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

    /// Distance above a text line's baseline to its optical vertical center
    /// (`(ascender + descender) / 2`), so the checkbox/remove button
    /// `.alignmentGuide(.firstTextBaseline)` centers on the item text's
    /// FIRST line specifically — not the whole multi-line block, and not the
    /// baseline itself. `itemFont` is `magnifiedFont(scaledFontSize(10))`
    /// (see `ContentView.magnifiedFont`); approximated here as
    /// `10 * fontScale` since the global magnification percent isn't
    /// threaded down to this view — close enough for an alignment offset.
    private var firstLineCenterOffset: CGFloat {
        let font = NSFont.systemFont(ofSize: 10 * fontScale)
        return (font.ascender + font.descender) / 2
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

import AppKit
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
/// below unchecked, viewport capped at ``visibleRowCount`` rows and
/// scrollable beyond that), a ghost add row whose TextField commits on
/// Enter and re-arms, and an "Open as Pane" footer. Hosted in a real
/// NSPopover so the TextField can take first responder (see
/// `SidebarWorkspaceTodoPopoverHost`).
struct SidebarWorkspaceChecklistPopover: View {
    let model: SidebarWorkspaceChecklistPopoverModel
    let actions: SidebarWorkspaceChecklistActions
    let onConsumeAddFieldActivation: () -> Void
    let onClose: @MainActor () -> Void

    @State private var pendingItemText = ""
    @FocusState private var addFieldFocused: Bool
    @State private var editingItemId: UUID?
    @State private var editingText = ""
    @FocusState private var editFieldFocused: Bool
    /// The keyboard-highlighted item: Up/Down from the add field moves it,
    /// Return toggles it when the add field is empty, and Cmd+Return always
    /// toggles it between completed and pending.
    @State private var highlightedItemId: UUID?
    /// Pointer position in ``Self/pointerSpaceName`` space (nil = outside).
    /// A REFERENCE box, not `@State` value storage: mouse-moved arrives per
    /// pixel, and a CGPoint state write per event would rebuild every
    /// non-lazy row at mouse frequency. Mutating the box invalidates
    /// nothing; only `hoveredItemId` (row-granular) drives renders.
    private final class PointerLocationBox {
        var location: CGPoint?
    }

    @State private var pointerLocation = PointerLocationBox()
    /// Item under the pointer (reveals the trailing delete button). Derived
    /// from pointer position + row geometry — never from per-row hover
    /// events, which die when content recreates or rows reflow under a
    /// resting pointer. Written only when the hovered ROW changes.
    @State private var hoveredItemId: UUID?
    /// Row frames in ``Self/pointerSpaceName`` space (via preference); update
    /// on scroll/reflow so hover self-corrects under a resting pointer.
    @State private var itemRowFrames: [UUID: CGRect] = [:]

    private static let pointerSpaceName = "checklistPopoverPointerSpace"

    private func rederiveHover(frames: [UUID: CGRect]) {
        let hovered = pointerLocation.location.flatMap { point in
            frames.first { $0.value.contains(point) }?.key
        }
        if hovered != hoveredItemId {
            hoveredItemId = hovered
        }
    }

    private static let itemFontSize: CGFloat = 13
    /// Checkbox glyphs draw at 13pt (the inline row's base is 8pt·scale).
    private static let checkboxPointSize: CGFloat = 13

    /// Single-line row height estimate (`itemFontSize` plus the row's own
    /// `.padding(.vertical, 2)` on both edges plus a little line-height
    /// headroom), used to cap the item list's scrollable viewport at
    /// ``visibleRowCount`` rows instead of the previous flat 460pt cap
    /// (≈23 rows).
    private static let itemRowHeightEstimate: CGFloat = itemFontSize + 6
    private static let visibleRowCount = 6
    private static let rowSpacing: CGFloat = 2

    /// Distance above a text line's baseline to its optical vertical center
    /// (`(ascender + descender) / 2`), so the checkbox/remove button
    /// `.alignmentGuide(.firstTextBaseline)` centers on the item text's
    /// FIRST line specifically — not the whole multi-line block, and not the
    /// baseline itself.
    private var firstLineCenterOffset: CGFloat {
        let font = NSFont.systemFont(ofSize: Self.itemFontSize)
        return (font.ascender + font.descender) / 2
    }

    /// Content height for `count` rows, capped at ``visibleRowCount`` rows —
    /// short lists get exactly their own height (no dead space), longer
    /// lists get the 6-row cap and scroll for the rest.
    private func scrollViewportHeight(forItemCount count: Int) -> CGFloat {
        guard count > 0 else { return 0 }
        let visibleCount = min(count, Self.visibleRowCount)
        return Self.itemRowHeightEstimate * CGFloat(visibleCount)
            + Self.rowSpacing * CGFloat(visibleCount - 1)
    }

    var body: some View {
        let ordered = SidebarWorkspaceChecklistDisplayPolicy.orderedItems(model.items)
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 6)
            if !ordered.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(ordered) { item in
                                itemRow(item)
                                    .id(item.id)
                            }
                        }
                        .padding(.horizontal, 8)
                    }
                    .frame(height: scrollViewportHeight(forItemCount: ordered.count))
                    // `anchor: nil` scrolls the minimal distance needed to
                    // bring the highlighted row fully into view — a no-op if
                    // it's already visible, matching arrow-key nav that
                    // should only move the viewport when it must.
                    .onChange(of: highlightedItemId) { _, newValue in
                        guard let newValue else { return }
                        proxy.scrollTo(newValue, anchor: nil)
                    }
                }
            }
            addItemRow(visible: ordered)
                .padding(.horizontal, 8)
                .padding(.bottom, 6)
            Divider()
            footer
        }
        .frame(width: 320, alignment: .leading)
        .coordinateSpace(name: Self.pointerSpaceName)
        // AppKit-owned pointer tracking (see PopoverPointerTracker's doc for
        // why SwiftUI hover modifiers can't be used here: their tracking
        // areas churn with content updates and drop the first post-mutation
        // event as a spurious "ended").
        .background(PopoverPointerTracker { location in
            pointerLocation.location = location
            rederiveHover(frames: itemRowFrames)
        })
        .onPreferenceChange(ChecklistPopoverRowFramesKey.self) { frames in
            itemRowFrames = frames
            rederiveHover(frames: frames)
        }
        .background(toggleHighlightedShortcutButton(visible: ordered))
        // Without this, the popover's window only gets promoted to key once,
        // at `popoverDidShow` — if the terminal-backed pane grabs key window
        // status back afterward (see `PopoverKeyWindowElevator`'s doc
        // comment), `.onContinuousHover`'s tracking areas stop firing
        // (SwiftUI hover tracking is gated on `.activeInKeyWindow`), so the
        // remove-item "x" stops revealing on hover. `SidebarWorkspaceStatusPopover`
        // already carries this same fix for its own popover.
        .background(PopoverKeyWindowElevator())
        .onAppear { addFieldFocused = true }
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
            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + firstLineCenterOffset }
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
                // No `lineLimit` — items wrap across multiple lines. The
                // checkbox/remove button align to this Text's FIRST line
                // only (`.firstTextBaseline`, offset by
                // `firstLineCenterOffset`), not the whole wrapped block.
                Text(item.text)
                    .font(.system(size: Self.itemFontSize))
                    .foregroundColor(isCompleted ? .secondary : .primary)
                    .strikethrough(isCompleted)
                    .opacity(isCompleted ? 0.6 : 1)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentShape(Rectangle())
                    .onTapGesture { beginItemEdit(item) }
            }
            Spacer(minLength: 0)
            removeItemButton(for: item)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + firstLineCenterOffset }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(highlightedItemId == item.id ? Color.primary.opacity(0.08) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            // Highlighting a row while the add field holds an in-progress
            // draft would leave both a "focused" item and a "focused" field
            // on screen at once, making Return's outcome ambiguous — only
            // set the highlight when there is no draft to disambiguate.
            guard pendingItemText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            highlightedItemId = item.id
        }
        // Hover is derived at the container level from pointer position +
        // this row's reported frame (see `hoveredItemId`'s doc comment) —
        // per-row hover callbacks die when the backing view is recreated
        // while the pointer rests in place.
        .background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: ChecklistPopoverRowFramesKey.self,
                    value: [item.id: proxy.frame(in: .named(Self.pointerSpaceName))]
                )
            }
        )
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

    /// Trailing hover-reveal delete affordance, in addition to the row's
    /// context-menu "Remove" entry. Always laid out at a fixed size (only
    /// `.opacity`/`.allowsHitTesting` toggle) so the row's height never jumps
    /// when the pointer enters/leaves.
    private func removeItemButton(for item: WorkspaceChecklistItem) -> some View {
        let isHovered = hoveredItemId == item.id
        return Button {
            actions.removeItem(item.id)
        } label: {
            CmuxSystemSymbolImage(systemName: "xmark.circle.fill", pointSize: Self.checkboxPointSize - 2)
                .foregroundColor(.secondary)
                .frame(width: Self.checkboxPointSize + 6, height: Self.checkboxPointSize + 6, alignment: .center)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .safeHelp(String(localized: "sidebar.checklist.removeItemTooltip", defaultValue: "Remove item"))
        .opacity(isHovered ? 1 : 0)
        .allowsHitTesting(isHovered)
        .accessibilityHidden(!isHovered)
        .accessibilityIdentifier("SidebarChecklistPopoverRemoveItemButton")
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
            .onKeyPress(.delete) { handleAddFieldDelete(visible: visible) }
            .onSubmit(commitPendingItem)
            .onExitCommand(perform: cancelPendingItem)
            .onChange(of: pendingItemText) { _, newValue in
                // A highlighted item plus live typed text is the ambiguous
                // dual-focus state Return can't resolve visually — as soon
                // as the draft becomes non-empty, drop the highlight.
                guard !newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                highlightedItemId = nil
            }
            .accessibilityIdentifier("SidebarChecklistPopoverAddItemField")
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
    }

    // MARK: Keyboard navigation + toggle

    /// Moves the highlight up/down through the visible items, clamping at the
    /// ends.
    private func moveHighlight(_ delta: Int, in visible: [WorkspaceChecklistItem]) -> KeyPress.Result {
        // Browsing (arrow-key highlight) and typing a new item are mutually
        // exclusive: only move the highlight while the draft is empty, so a
        // highlighted item and live typed text never coexist.
        guard pendingItemText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .ignored
        }
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

    /// Backspace with an empty draft removes the highlighted item — a
    /// keyboard-driven delete alongside the row's hover "x" and context-menu
    /// "Remove", for browsing-mode (Up/Down-highlighted) deletion without
    /// reaching for the mouse.
    private func handleAddFieldDelete(visible: [WorkspaceChecklistItem]) -> KeyPress.Result {
        guard pendingItemText.isEmpty else { return .ignored }
        guard let id = highlightedItemId,
              visible.contains(where: { $0.id == id }) else { return .ignored }
        actions.removeItem(id)
        highlightedItemId = nil
        return .handled
    }

    /// A zero-size button that binds the configured shortcut to toggling the highlighted
    /// item. A `.keyboardShortcut` fires even while the add field is focused
    /// (a plain TextField only consumes bare Return via `onSubmit`), so the
    /// toggle works without stealing focus from the add field. Also exposed
    /// as the configurable `toggleChecklistItemComplete` action in Settings.
    @ViewBuilder
    private func toggleHighlightedShortcutButton(visible: [WorkspaceChecklistItem]) -> some View {
        let shortcut = KeyboardShortcutSettings.shortcut(for: .toggleChecklistItemComplete)
        if let key = shortcut.keyEquivalent {
            Button {
                toggleHighlighted(in: visible)
            } label: { Color.clear.frame(width: 0, height: 0) }
                .buttonStyle(.plain)
                .keyboardShortcut(key, modifiers: shortcut.eventModifiers)
                .accessibilityHidden(true)
        }
    }

    /// Return/configured shortcut toggles the highlighted item; no-op when nothing is
    /// highlighted.
    private func toggleHighlighted(in visible: [WorkspaceChecklistItem]) {
        guard let id = highlightedItemId,
              let item = visible.first(where: { $0.id == id }) else { return }
        actions.setItemState(item.id, item.state == .completed ? .pending : .completed)
    }

    /// Enter commits the trimmed text and re-arms the field (a fresh, empty,
    /// focused add field) for the next item. Focus loss never commits: a
    /// half-typed draft stays in the field until Return submits it or the
    /// popover closes.
    private func commitPendingItem() {
        let text = pendingItemText
        pendingItemText = ""
        onConsumeAddFieldActivation()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        actions.addItem(text)
        addFieldFocused = true
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
            // Close FIRST: NSPopover teardown restores the parent window's
            // previous first responder, which would clobber the pane focus /
            // armed add field that openPane() sets up.
            onClose()
            actions.openPane()
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

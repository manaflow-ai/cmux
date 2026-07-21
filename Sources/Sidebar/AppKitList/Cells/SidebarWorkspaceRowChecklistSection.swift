import AppKit
import CmuxWorkspaces
import SwiftUI

/// Pure-AppKit parity port of the legacy `SidebarWorkspaceChecklistSection`:
/// a progress summary line plus either an inline expansion (ordered items in
/// a 6-row-capped scrollable viewport, tap-to-edit, attachments, hover
/// delete, ghost add row) or an anchored checklist popover, per the
/// `sidebar.beta.workspaceTodos.checklistStyle` setting. The popover reuses
/// the legacy SwiftUI `SidebarWorkspaceChecklistPopover` wholesale (popovers
/// sit off the scroll path).
///
/// All height-affecting state is model-derived (expansion, popover
/// presentation, add-field activation token, editing item id) so the height
/// cache's prototype cell measures exactly what the live cell shows.
@MainActor
final class SidebarRowChecklistSection: NSView {
    private let summaryLine = SidebarRowChecklistSummaryLine()
    private let scrollView = NSScrollView()
    private let itemsDocumentView = SidebarRowChecklistFlippedView()
    /// Item lines keyed by item ID (legacy `ForEach` identity): positional
    /// pooling reassigned lines across items during reorders, which tore
    /// down and re-seeded an active editor with stale text.
    private var itemLinesById: [UUID: SidebarRowChecklistItemLine] = [:]
    private var orderedLines: [SidebarRowChecklistItemLine] = []
    private var freeLines: [SidebarRowChecklistItemLine] = []
    private let addRow = SidebarRowChecklistAddRow()
    private let popoverPresenter = SidebarRowSwiftUIPopoverPresenter()

    private var model: SidebarWorkspaceRowModel?
    private var actions: SidebarAppKitRowActions?
    private var orderedItems: [WorkspaceChecklistItem] = []
    private var showsExpandedList = false
    private var usesPopoverStyle = false
    private var canAddItems = false
    /// Re-present latch after an AppKit-side popover close: stale configure
    /// ticks that still say "presented" must not instantly re-open the
    /// popover the user just dismissed (same class of churn loop the legacy
    /// `SidebarWorkspaceTodoPopoverHost` guards with `awaitingDismissAck`).
    private var awaitingPopoverDismissAck = false
    private var lastAddFieldToken = 0
    private var lastPopoverModel: SidebarWorkspaceChecklistPopoverModel?
    /// Presentation deferred to `layout()`: configure can run before this
    /// view has a window or resolved bounds, and anchoring against a stale
    /// zero-width frame pins the popover to the row's left edge (the legacy
    /// anchor-collapse bug class).
    private var pendingPopoverPresentation = false
    /// Container write-back captured at present time, so an external close —
    /// or this pooled cell being reused for another workspace — clears the
    /// PRESENTED workspace's state even after `self.actions` was replaced
    /// (legacy host dismantle parity: unmount writes `isPresented = false`).
    private var activePopoverDismissContext: (() -> Void)?

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(summaryLine)
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.horizontalScrollElasticity = .none
        scrollView.documentView = itemsDocumentView
        scrollView.isHidden = true
        addSubview(scrollView)
        addRow.isHidden = true
        addSubview(addRow)
        popoverPresenter.minWidth = 320
        popoverPresenter.maxHeight = 520
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: Configure

    func configure(
        model: SidebarWorkspaceRowModel,
        palette: SidebarRowPalette,
        actions: SidebarAppKitRowActions
    ) {
        let previousWorkspaceId = self.model?.workspaceId
        self.model = model
        self.actions = actions
        if previousWorkspaceId != model.workspaceId {
            awaitingPopoverDismissAck = false
            lastAddFieldToken = 0
            lastPopoverModel = nil
            if popoverPresenter.isShown {
                popoverPresenter.close()
                // Reused for another workspace: write the OLD workspace's
                // presentation state back to closed (captured at present
                // time), or scrolling back would re-present a popover the
                // legacy host dismantles for good.
                activePopoverDismissContext?()
            }
            activePopoverDismissContext = nil
            // Fresh scroll position per workspace (legacy rows are distinct
            // SwiftUI views, so offsets never carry across workspaces).
            scrollView.contentView.scroll(to: .zero)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }

        let snapshot = model.snapshot
        canAddItems = model.todoControlsEnabled
        usesPopoverStyle = model.settings.workspaceTodoChecklistStyle == .popover
        // Legacy mount policy (`SidebarWorkspaceTodoMinimalVisibility`):
        // content, a pending add request, or an OPEN popover keep the section
        // mounted — unmounting would dismantle the popover's anchor.
        let mounted = !snapshot.checklistItems.isEmpty
            || (canAddItems
                && (model.checklistAddFieldActivationToken > 0 || model.isChecklistPopoverPresented))
        isHidden = !mounted
        guard mounted else {
            if popoverPresenter.isShown {
                popoverPresenter.close()
                // Legacy-host dismantle parity: an unmount while presented
                // (e.g. todo controls disabled with an empty checklist) must
                // write the container's presentation state back to closed,
                // or re-enabling the feature re-presents without user action.
                activePopoverDismissContext?()
            }
            activePopoverDismissContext = nil
            // Unmounted = fully closed: a future mount is a fresh session.
            // Leaving the dismissal latch and token tracker armed dropped
            // the NEXT "Add Checklist Item…" request — consuming the token
            // removes it, so the next request is token 1 again and matched
            // the stale tracker instead of clearing the latch.
            awaitingPopoverDismissAck = false
            lastAddFieldToken = 0
            lastPopoverModel = nil
            pendingPopoverPresentation = false
            // Recycled cells must not retain the previous workspace through
            // configured children: field closures and action bundles capture
            // the Workspace strongly.
            resetTransientChildren()
            return
        }

        // Same color/font roles the legacy section receives from TabItemView.
        let primary = palette.secondary(0.9)
        let secondary = palette.secondary(0.65)

        summaryLine.isHidden = snapshot.checklistTotalCount == 0
        if !summaryLine.isHidden {
            summaryLine.configure(
                snapshot: snapshot,
                model: model,
                primary: primary,
                secondary: secondary,
                toolTip: usesPopoverStyle
                    ? String(localized: "sidebar.checklist.popoverTooltip", defaultValue: "Show checklist")
                    : (model.isChecklistExpanded
                        ? String(localized: "sidebar.checklist.collapseTooltip", defaultValue: "Hide checklist items")
                        : String(localized: "sidebar.checklist.expandTooltip", defaultValue: "Show checklist items")),
                onClick: { [weak self] in
                    guard let self, let model = self.model else { return }
                    if self.usesPopoverStyle {
                        self.actions?.onChecklistPopoverPresentedChange(!model.isChecklistPopoverPresented)
                    } else {
                        self.actions?.onToggleChecklistExpansion()
                    }
                }
            )
        }

        // Popover style never expands inline; the summary opens the popover.
        showsExpandedList = !usesPopoverStyle
            && (model.isChecklistExpanded || snapshot.checklistTotalCount == 0)
        // Completed items sink below unchecked ones (legacy display policy);
        // ALL items render — the viewport caps at 6 rows and scrolls beyond.
        orderedItems = showsExpandedList
            ? SidebarWorkspaceChecklistDisplayPolicy.orderedItems(snapshot.checklistItems)
            : []
        scrollView.isHidden = !showsExpandedList || orderedItems.isEmpty
        // Reuse lines by item ID so reorders MOVE a line (with any active
        // editor) instead of reassigning it to a different item. Reclamation
        // walks the previous ORDERED lines by identity, not the ID map:
        // persisted data can carry duplicate item IDs (restore does not
        // dedupe), and map-only bookkeeping would orphan the earlier
        // duplicate's line as a leaked, still-visible subview.
        var previousById = itemLinesById
        let previousLines = orderedLines
        var reusedLines = Set<ObjectIdentifier>()
        itemLinesById.removeAll(keepingCapacity: true)
        orderedLines = orderedItems.map { item in
            let line = previousById.removeValue(forKey: item.id)
                ?? freeLines.popLast()
                ?? SidebarRowChecklistItemLine()
            if line.superview !== itemsDocumentView {
                itemsDocumentView.addSubview(line)
            }
            line.isHidden = false
            reusedLines.insert(ObjectIdentifier(line))
            itemLinesById[item.id] = line
            line.configure(
                item,
                model: model,
                primary: primary,
                secondary: secondary,
                isEditing: model.editingChecklistItemId == item.id,
                actions: actions
            )
            return line
        }
        // Every previous line not reused this pass — vanished items AND
        // duplicate-ID casualties — clears its captured workspace state and
        // parks for reuse.
        for line in previousLines where !reusedLines.contains(ObjectIdentifier(line)) {
            line.resetForReuse()
            line.isHidden = true
            freeLines.append(line)
        }

        let isAdding = showsExpandedList && canAddItems && model.checklistAddFieldActivationToken > 0
        addRow.isHidden = !(showsExpandedList && canAddItems)
        if addRow.isHidden {
            addRow.resetForReuse()
        } else {
            addRow.configure(
                workspaceId: model.workspaceId,
                model: model,
                secondary: secondary,
                primary: primary,
                isAdding: isAdding,
                armToken: model.checklistAddFieldActivationToken,
                onBeginAdding: { [weak self] in
                    guard let model = self?.model else { return }
                    // Arm via the same activation-token path the context menu
                    // uses, so the armed field is part of the row model and
                    // the prototype height measurement sees it.
                    WorkspaceTodoActions.requestChecklistAddField(workspaceId: model.workspaceId)
                },
                // Workspace-bound closures frozen for THIS configure pass:
                // resolving through the pooled section's `self.actions` at
                // fire time routed teardown-triggered commits to whichever
                // workspace the cell showed next.
                onCommit: { [addItem = actions.checklistAddItem] text in
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    addItem(trimmed)
                },
                onCancel: { [consumeToken = actions.onConsumeChecklistAddFieldActivation] in
                    // Esc (or focus loss with an empty draft) dismisses.
                    consumeToken()
                }
            )
        }

        reconcileChecklistPopover(model: model, actions: actions)
        needsLayout = true
    }

    // MARK: Checklist popover (popover style)

    private func reconcileChecklistPopover(
        model: SidebarWorkspaceRowModel,
        actions: SidebarAppKitRowActions
    ) {
        // An explicit add request (token bump) clears the external-dismissal
        // latch so a context-menu/palette request can always re-present.
        let token = model.checklistAddFieldActivationToken
        if token > 0, token != lastAddFieldToken {
            awaitingPopoverDismissAck = false
        }
        lastAddFieldToken = token
        guard usesPopoverStyle, model.isChecklistPopoverPresented else {
            if !model.isChecklistPopoverPresented {
                awaitingPopoverDismissAck = false
            }
            pendingPopoverPresentation = false
            if popoverPresenter.isShown {
                popoverPresenter.close()
            }
            // The container already reflects the closed state on this path;
            // drop the captured write-back without invoking it.
            activePopoverDismissContext = nil
            return
        }
        guard !awaitingPopoverDismissAck else { return }

        if popoverPresenter.isShown {
            // Live refresh only when the rendered model actually changed
            // (configure also runs for hover/selection repaints).
            let popoverModel = checklistPopoverModel(model)
            if lastPopoverModel != popoverModel {
                lastPopoverModel = popoverModel
                popoverPresenter.update(checklistPopoverContent(popoverModel, actions: actions))
            }
        } else {
            // Defer to layout(): this view may not have a window or resolved
            // bounds yet (fresh cell mid-configure).
            pendingPopoverPresentation = true
            needsLayout = true
        }
    }

    private func presentPendingChecklistPopoverIfNeeded() {
        guard pendingPopoverPresentation else { return }
        guard let model, let actions, window != nil, bounds.width > 1 else { return }
        pendingPopoverPresentation = false
        guard !popoverPresenter.isShown else { return }
        let popoverModel = checklistPopoverModel(model)
        lastPopoverModel = popoverModel
        // Capture the presented workspace's write-back closures NOW: by the
        // time a dismissal fires, `self.actions` may already belong to a
        // different workspace (pooled cell reuse).
        let presentedChange = actions.onChecklistPopoverPresentedChange
        let consumeToken = actions.onConsumeChecklistAddFieldActivation
        activePopoverDismissContext = {
            presentedChange(false)
            consumeToken()
        }
        popoverPresenter.onExternalDismiss = { [weak self] in
            // AppKit closed us (click-away / deactivation): latch until the
            // container acknowledges, and consume any pending add request
            // like the legacy presented-binding write-back does.
            self?.awaitingPopoverDismissAck = true
            presentedChange(false)
            consumeToken()
            self?.activePopoverDismissContext = nil
        }
        // Legacy anchor: the section's top-trailing corner, opening to the
        // right (`preferredEdge: .maxX`, min width 320, max 520).
        popoverPresenter.present(
            checklistPopoverContent(popoverModel, actions: actions),
            relativeTo: NSRect(x: max(0, bounds.width - 1), y: 0, width: 1, height: 1),
            of: self,
            preferredEdge: .maxX
        )
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if pendingPopoverPresentation, window != nil {
            needsLayout = true
        }
    }

    private func checklistPopoverModel(_ model: SidebarWorkspaceRowModel) -> SidebarWorkspaceChecklistPopoverModel {
        let snapshot = model.snapshot
        return SidebarWorkspaceChecklistPopoverModel(
            workspaceTitle: snapshot.title,
            items: snapshot.checklistItems,
            completedCount: snapshot.checklistCompletedCount,
            totalCount: snapshot.checklistTotalCount,
            addFieldActivationToken: model.checklistAddFieldActivationToken,
            canAddItems: canAddItems
        )
    }

    private func checklistPopoverContent(
        _ popoverModel: SidebarWorkspaceChecklistPopoverModel,
        actions: SidebarAppKitRowActions
    ) -> AnyView {
        AnyView(SidebarWorkspaceChecklistPopover(
            model: popoverModel,
            actions: Self.checklistActions(from: actions),
            onConsumeAddFieldActivation: actions.onConsumeChecklistAddFieldActivation,
            onClose: { [weak self] in
                self?.closeChecklistPopoverFromContent()
            }
        ))
    }

    private func closeChecklistPopoverFromContent() {
        popoverPresenter.close()
        activePopoverDismissContext?()
        activePopoverDismissContext = nil
    }

    private static func checklistActions(
        from actions: SidebarAppKitRowActions
    ) -> SidebarWorkspaceChecklistActions {
        SidebarWorkspaceChecklistActions(
            setItemState: actions.checklistSetItemState,
            removeItem: actions.checklistRemoveItem,
            addItem: actions.checklistAddItem,
            editItem: actions.checklistEditItem,
            moveItem: actions.checklistMoveItem,
            openPane: actions.checklistOpenPane,
            addAttachments: actions.checklistAddAttachments,
            removeAttachment: actions.checklistRemoveAttachment,
            openAttachments: actions.checklistOpenAttachments
        )
    }

    private func resetTransientChildren() {
        for line in orderedLines {
            line.resetForReuse()
            line.isHidden = true
            freeLines.append(line)
        }
        orderedLines.removeAll()
        itemLinesById.removeAll(keepingCapacity: true)
        addRow.resetForReuse()
    }

    // MARK: Measurement + layout

    /// Legacy single-line row height estimate (`11 * fontScale + 4`); the
    /// expanded viewport caps at 6 estimated rows and scrolls for the rest.
    private func itemRowHeightEstimate(_ model: SidebarWorkspaceRowModel) -> CGFloat {
        11 * model.fontScale + 4
    }

    private static let visibleRowCount = 6
    private static let rowSpacing: CGFloat = 2
    /// The expanded list's `.padding(.leading, 2)`.
    private static let expandedLeadingPadding: CGFloat = 2

    private func scrollViewportHeight(forItemCount count: Int, model: SidebarWorkspaceRowModel) -> CGFloat {
        guard count > 0 else { return 0 }
        let visibleCount = min(count, Self.visibleRowCount)
        return itemRowHeightEstimate(model) * CGFloat(visibleCount)
            + Self.rowSpacing * CGFloat(visibleCount - 1)
    }

    func measuredHeight(width: CGFloat) -> CGFloat {
        guard !isHidden, let model else { return 0 }
        var height: CGFloat = 0
        var hasBlock = false
        func addBlock(_ blockHeight: CGFloat) {
            guard blockHeight > 0 else { return }
            if hasBlock { height += Self.rowSpacing }
            height += blockHeight
            hasBlock = true
        }
        if !summaryLine.isHidden {
            addBlock(summaryLine.measuredHeight(width: width))
        }
        if showsExpandedList {
            if !orderedItems.isEmpty {
                addBlock(scrollViewportHeight(forItemCount: orderedItems.count, model: model))
            }
            if !addRow.isHidden {
                addBlock(addRow.measuredHeight(width: max(10, width - Self.expandedLeadingPadding)))
            }
        }
        return height
    }

    override func layout() {
        super.layout()
        guard let model else { return }
        var y: CGFloat = 0
        var hasBlock = false
        func advance(_ blockHeight: CGFloat) -> CGFloat {
            if hasBlock { y += Self.rowSpacing }
            let top = y
            y += blockHeight
            hasBlock = true
            return top
        }
        if !summaryLine.isHidden {
            let height = summaryLine.measuredHeight(width: bounds.width)
            summaryLine.frame = NSRect(x: 0, y: advance(height), width: bounds.width, height: height)
        }
        if showsExpandedList, !scrollView.isHidden {
            let viewportHeight = scrollViewportHeight(forItemCount: orderedItems.count, model: model)
            let top = advance(viewportHeight)
            let viewportWidth = max(10, bounds.width - Self.expandedLeadingPadding)
            scrollView.frame = NSRect(
                x: Self.expandedLeadingPadding, y: top,
                width: viewportWidth, height: viewportHeight
            )
            layoutItems(width: scrollView.contentSize.width)
        }
        if !addRow.isHidden {
            let width = max(10, bounds.width - Self.expandedLeadingPadding)
            let height = addRow.measuredHeight(width: width)
            addRow.frame = NSRect(
                x: Self.expandedLeadingPadding, y: advance(height),
                width: width, height: height
            )
        }
        presentPendingChecklistPopoverIfNeeded()
    }

    private func layoutItems(width: CGFloat) {
        var y: CGFloat = 0
        for (index, line) in orderedLines.enumerated() {
            if index > 0 { y += Self.rowSpacing }
            let height = line.measuredHeight(width: width)
            line.frame = NSRect(x: 0, y: y, width: width, height: height)
            y += height
        }
        itemsDocumentView.frame = NSRect(x: 0, y: 0, width: width, height: y)
    }
}

/// Flipped document view for the checklist scroll viewport.
@MainActor
final class SidebarRowChecklistFlippedView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - Summary line

/// The one-line progress summary: leading `checklist` glyph
/// (`checkmark.circle.fill` when everything is done), a monospaced-digit
/// "completed/total" count, and — while anything is unchecked — a dim "·"
/// plus first-unchecked-item preview. The whole line is one full-width click
/// target (legacy: the Button's contentShape spans the row).
@MainActor
final class SidebarRowChecklistSummaryLine: NSControl {
    private let iconView = NSImageView()
    private let countLabel = SidebarRowTextView(lines: 1)
    private let separatorLabel = SidebarRowTextView(lines: 1)
    private let previewLabel = SidebarRowTextView(lines: 1)
    private var onClick: (() -> Void)?

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        iconView.imageScaling = .scaleProportionallyDown
        addSubview(iconView)
        addSubview(countLabel)
        separatorLabel.isHidden = true
        addSubview(separatorLabel)
        previewLabel.isHidden = true
        addSubview(previewLabel)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        snapshot: SidebarWorkspaceSnapshotBuilder.Snapshot,
        model: SidebarWorkspaceRowModel,
        primary: NSColor,
        secondary: NSColor,
        toolTip: String,
        onClick: @escaping () -> Void
    ) {
        self.onClick = onClick
        self.toolTip = toolTip
        let allDone = snapshot.checklistCompletedCount == snapshot.checklistTotalCount
        iconView.image = RenderableSystemSymbol.configuredAppKitImage(
            systemName: allDone ? "checkmark.circle.fill" : "checklist",
            pointSize: model.scaled(8),
            weight: nil
        )
        iconView.contentTintColor = secondary
        let summaryFont = NSFont.monospacedDigitSystemFont(ofSize: model.scaled(10), weight: .semibold)
        let itemFont = NSFont.systemFont(ofSize: model.scaled(10))
        countLabel.stringValue = "\(snapshot.checklistCompletedCount)/\(snapshot.checklistTotalCount)"
        countLabel.font = summaryFont
        countLabel.textColor = primary
        let preview = snapshot.checklistFirstUncheckedText
        separatorLabel.isHidden = preview == nil
        previewLabel.isHidden = preview == nil
        if let preview {
            separatorLabel.stringValue = "·"
            separatorLabel.font = summaryFont
            separatorLabel.textColor = secondary
            previewLabel.stringValue = preview
            previewLabel.font = itemFont
            previewLabel.textColor = secondary
        }
        setAccessibilityRole(.button)
        setAccessibilityIdentifier("SidebarChecklistSummaryLine")
        needsLayout = true
    }

    func measuredHeight(width: CGFloat) -> CGFloat {
        let iconHeight = iconView.image?.size.height ?? 0
        var height = max(iconHeight, countLabel.sidebarNaturalCellSize.height)
        if !previewLabel.isHidden {
            height = max(height, previewLabel.sidebarNaturalCellSize.height)
        }
        return ceil(height)
    }

    override func layout() {
        super.layout()
        var x: CGFloat = 0
        let iconSize = iconView.image?.size ?? .zero
        iconView.frame = NSRect(
            x: 0, y: (bounds.height - iconSize.height) / 2,
            width: iconSize.width, height: iconSize.height
        )
        x += iconSize.width + 4
        let countSize = countLabel.sidebarNaturalCellSize
        countLabel.frame = NSRect(
            x: x, y: (bounds.height - countSize.height) / 2,
            width: ceil(countSize.width), height: countSize.height
        )
        x += ceil(countSize.width) + 4
        if !separatorLabel.isHidden {
            let separatorSize = separatorLabel.sidebarNaturalCellSize
            separatorLabel.frame = NSRect(
                x: x, y: (bounds.height - separatorSize.height) / 2,
                width: ceil(separatorSize.width), height: separatorSize.height
            )
            x += ceil(separatorSize.width) + 4
            let previewSize = previewLabel.sidebarNaturalCellSize
            previewLabel.frame = NSRect(
                x: x, y: (bounds.height - previewSize.height) / 2,
                width: max(0, bounds.width - x), height: previewSize.height
            )
        }
    }

    override func mouseDown(with event: NSEvent) {
        // Swallow so the table row action does not also fire (legacy Button
        // consumes the click without selecting the row), and dim while
        // pressed like the SwiftUI plain Button this ports.
        alphaValue = SidebarRowPressedDim.pressedAlpha
    }

    override func mouseUp(with event: NSEvent) {
        alphaValue = 1
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return }
        onClick?()
    }

    /// VoiceOver/keyboard activation parity with the legacy SwiftUI Button.
    override func accessibilityPerformPress() -> Bool {
        guard let onClick else { return false }
        onClick()
        return true
    }
}

// MARK: - Item line

/// One checklist item row: state checkbox, wrapping item text (tap-to-edit
/// swaps in a focused field), always-visible attachment menu, and a
/// hover-revealed remove button in a reserved trailing slot. Right-click
/// offers Edit / Mark In Progress / Remove (legacy context menu).
@MainActor
final class SidebarRowChecklistItemLine: NSView {
    private let checkbox = SidebarHeaderGlyphButton()
    private let textLabel = SidebarRowTextView(lines: 0)
    private let textClickOverlay = SidebarRowChecklistTransparentButton()
    private var editField: FocusGrabbingTextField?
    private var editFieldBridge: SidebarRowChecklistFieldBridge?
    private var editingItemId: UUID?
    private let attachmentButton = SidebarRowChecklistAttachmentButton()
    private let removeButton = SidebarHeaderGlyphButton()
    private var trackingArea: NSTrackingArea?
    private var item: WorkspaceChecklistItem?
    private var model: SidebarWorkspaceRowModel?
    private var actions: SidebarAppKitRowActions?
    private var isEditing = false

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(checkbox)
        addSubview(textLabel)
        addSubview(textClickOverlay)
        addSubview(attachmentButton)
        removeButton.isHidden = true
        addSubview(removeButton)
        setAccessibilityIdentifier("SidebarChecklistItemRow")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        _ item: WorkspaceChecklistItem,
        model: SidebarWorkspaceRowModel,
        primary: NSColor,
        secondary: NSColor,
        isEditing: Bool,
        actions: SidebarAppKitRowActions
    ) {
        if self.item?.id != item.id {
            // Pooled-line reuse: never carry a hover-revealed remove button
            // to a different item (the tracking area re-derives on the next
            // pointer move).
            removeButton.isHidden = true
        }
        self.item = item
        self.model = model
        self.actions = actions

        let completed = item.state == .completed
        let symbol: String
        switch item.state {
        case .completed: symbol = "checkmark.square.fill"
        case .inProgress: symbol = "minus.square"
        default: symbol = "square"
        }
        checkbox.glyphImage = RenderableSystemSymbol.configuredAppKitImage(
            systemName: symbol, pointSize: model.scaled(8), weight: nil
        )
        checkbox.contentTintColor = completed ? secondary : primary
        checkbox.toolTip = completed
            ? String(localized: "sidebar.checklist.uncheckTooltip", defaultValue: "Mark as pending")
            : String(localized: "sidebar.checklist.checkTooltip", defaultValue: "Mark as completed")
        checkbox.onClick = { [weak self] in
            guard let self, let item = self.item else { return }
            let next: WorkspaceChecklistItem.State = item.state == .completed ? .pending : .completed
            self.actions?.checklistSetItemState(item.id, next)
        }

        let itemFont = NSFont.systemFont(ofSize: model.scaled(10))
        // Keep the field's `font` in sync with the attributed text: the
        // first-line-center math reads it.
        textLabel.font = itemFont
        if completed {
            // Legacy completed treatment: secondary color at 0.6 opacity
            // (multiplied, like SwiftUI `.opacity`) plus strikethrough.
            textLabel.attributedStringValue = NSAttributedString(
                string: item.text,
                attributes: [
                    .font: itemFont,
                    .foregroundColor: secondary.withAlphaComponent(secondary.alphaComponent * 0.6),
                    .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                ]
            )
        } else {
            textLabel.attributedStringValue = NSAttributedString(
                string: item.text,
                attributes: [
                    .font: itemFont,
                    .foregroundColor: primary,
                ]
            )
        }
        textClickOverlay.onClick = { [weak self] in
            guard let self, let item = self.item else { return }
            self.actions?.onBeginChecklistItemEdit(item.id)
        }

        reconcileEditField(
            item: item,
            model: model,
            primary: primary,
            isEditing: isEditing,
            actions: actions
        )

        attachmentButton.configure(
            item: item,
            model: model,
            color: secondary,
            actions: actions
        )

        removeButton.glyphImage = RenderableSystemSymbol.configuredAppKitImage(
            systemName: "xmark.circle.fill", pointSize: model.scaled(9), weight: nil
        )
        removeButton.contentTintColor = secondary
        removeButton.toolTip = String(localized: "sidebar.checklist.removeItemTooltip", defaultValue: "Remove item")
        removeButton.onClick = { [weak self] in
            guard let self, let item = self.item else { return }
            self.actions?.checklistRemoveItem(item.id)
        }
        needsLayout = true
    }

    private func reconcileEditField(
        item: WorkspaceChecklistItem,
        model: SidebarWorkspaceRowModel,
        primary: NSColor,
        isEditing: Bool,
        actions: SidebarAppKitRowActions?
    ) {
        self.isEditing = isEditing
        textLabel.isHidden = isEditing
        textClickOverlay.isHidden = isEditing
        guard isEditing else {
            editField?.removeFromSuperview()
            editField = nil
            editFieldBridge = nil
            editingItemId = nil
            return
        }
        guard editField == nil || editingItemId != item.id else {
            editField?.font = .systemFont(ofSize: 11 * model.fontScale)
            return
        }
        editField?.removeFromSuperview()
        // Fresh field per edit session (legacy recreates via view identity):
        // `FocusGrabbingTextField` takes first responder when it attaches to
        // the window, and select-all marks the edit variant.
        let field = FocusGrabbingTextField(string: item.text)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.cell?.usesSingleLineMode = true
        field.lineBreakMode = .byTruncatingTail
        field.font = .systemFont(ofSize: 11 * model.fontScale)
        field.textColor = primary
        field.caretColor = primary
        field.placeholderString = String(localized: "sidebar.checklist.editItemPlaceholder", defaultValue: "Item text")
        field.selectsAllOnFocus = true
        field.setAccessibilityLabel(field.placeholderString ?? "")
        field.setAccessibilityIdentifier("SidebarChecklistEditItemField")
        // Capture the edited item's identity and its workspace's action
        // bundle at field-creation time: the pooled line's `self.item`/
        // `self.actions` are overwritten by reconfiguration (ordering
        // changes, cell reuse) BEFORE the old editor tears down, and a
        // teardown-triggered focus-loss commit must not write the draft
        // into whichever item the line shows next.
        let editedItemId = item.id
        guard let editActions = actions else { return }
        let bridge = SidebarRowChecklistFieldBridge(
            onCommit: { text in
                // Enter (or focus loss) commits trimmed text; empty keeps the
                // old text (legacy `commitItemEdit`).
                editActions.onBeginChecklistItemEdit(nil)
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                editActions.checklistEditItem(editedItemId, trimmed)
            },
            onCancel: {
                editActions.onBeginChecklistItemEdit(nil)
            }
        )
        field.delegate = bridge
        editFieldBridge = bridge
        editField = field
        editingItemId = item.id
        // Valid frame BEFORE the window attach (see the add row's comment):
        // a zero-frame focus grab mis-sizes the field editor's dark box.
        if let metrics = metrics(width: max(bounds.width, 100)) {
            let fieldHeight = 11 * model.fontScale + 4
            field.frame = NSRect(
                x: metrics.checkbox.width + 4, y: 0,
                width: metrics.textWidth, height: fieldHeight
            )
        }
        addSubview(field)
        SidebarRowChecklistFieldBridge.clearFieldEditorBackground(field)
        needsLayout = true
    }

    /// Legacy `firstLineCenterOffset`: accessories center on the item text's
    /// FIRST line. The offset font intentionally approximates the item font
    /// without global magnification, matching the SwiftUI implementation.
    private func firstLineCenter(model: SidebarWorkspaceRowModel, itemFont: NSFont) -> CGFloat {
        let approximation = NSFont.systemFont(ofSize: 10 * model.fontScale)
        return itemFont.ascender - (approximation.ascender + approximation.descender) / 2
    }

    private func metrics(width: CGFloat) -> (
        checkbox: NSSize, attach: NSSize, removeSlot: CGFloat, textWidth: CGFloat
    )? {
        guard let model else { return nil }
        let checkboxSize = checkbox.glyphImage?.size ?? .zero
        let attachSize = attachmentButton.measuredSize()
        let removeSlot = 9 * model.fontScale + 8
        // HStack(spacing: 4): checkbox·text·Spacer·attachment·remove — the
        // spacer contributes two spacings even at zero width.
        let textWidth = max(10, width - checkboxSize.width - 4 - 8 - attachSize.width - 4 - removeSlot)
        return (checkboxSize, attachSize, removeSlot, textWidth)
    }

    /// SwiftUI's first-baseline HStack grows the row so the accessories
    /// (whose optical centers sit on the first text line) fit fully — the
    /// text shifts DOWN when an accessory is taller than the space above the
    /// first-line center. `textTop` is that shift.
    private func verticalMetrics(
        model: SidebarWorkspaceRowModel,
        metrics: (checkbox: NSSize, attach: NSSize, removeSlot: CGFloat, textWidth: CGFloat)
    ) -> (textTop: CGFloat, lineCenter: CGFloat) {
        let itemFont = textLabel.font ?? NSFont.systemFont(ofSize: model.scaled(10))
        let center = firstLineCenter(model: model, itemFont: itemFont)
        let maxAccessoryHalf = max(
            metrics.checkbox.height / 2,
            metrics.attach.height / 2,
            metrics.removeSlot / 2
        )
        let textTop = max(0, maxAccessoryHalf - center)
        return (textTop, textTop + center)
    }

    func measuredHeight(width: CGFloat) -> CGFloat {
        guard !isHidden, let model, let metrics = metrics(width: width) else { return 0 }
        let vertical = verticalMetrics(model: model, metrics: metrics)
        let contentHeight: CGFloat
        if isEditing {
            contentHeight = 11 * model.fontScale + 4
        } else {
            contentHeight = textLabel.measuredHeight(width: metrics.textWidth)
        }
        let accessoryExtent = vertical.lineCenter + max(
            metrics.checkbox.height / 2,
            metrics.attach.height / 2,
            metrics.removeSlot / 2
        )
        return ceil(max(vertical.textTop + contentHeight, accessoryExtent))
    }

    override func layout() {
        super.layout()
        guard let model, let metrics = metrics(width: bounds.width) else { return }
        let vertical = verticalMetrics(model: model, metrics: metrics)
        checkbox.frame = NSRect(
            x: 0, y: vertical.lineCenter - metrics.checkbox.height / 2,
            width: metrics.checkbox.width, height: metrics.checkbox.height
        )
        let textX = metrics.checkbox.width + 4
        if isEditing, let editField {
            let fieldHeight = 11 * model.fontScale + 4
            editField.frame = NSRect(
                x: textX, y: max(0, vertical.lineCenter - fieldHeight / 2),
                width: metrics.textWidth, height: fieldHeight
            )
        } else {
            let textHeight = textLabel.measuredHeight(width: metrics.textWidth)
            textLabel.frame = NSRect(
                x: textX, y: vertical.textTop,
                width: metrics.textWidth, height: textHeight
            )
            textClickOverlay.frame = textLabel.frame
        }
        removeButton.frame = NSRect(
            x: bounds.width - metrics.removeSlot,
            y: vertical.lineCenter - metrics.removeSlot / 2,
            width: metrics.removeSlot, height: metrics.removeSlot
        )
        attachmentButton.frame = NSRect(
            x: removeButton.frame.minX - 4 - metrics.attach.width,
            y: vertical.lineCenter - metrics.attach.height / 2,
            width: metrics.attach.width, height: metrics.attach.height
        )
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let next = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(next)
        trackingArea = next
    }

    override func mouseEntered(with event: NSEvent) {
        removeButton.isHidden = false
    }

    override func mouseExited(with event: NSEvent) {
        removeButton.isHidden = true
    }

    /// Reuse teardown: drop the item, action bundle, editor, and click
    /// closures so a hidden pooled line stops retaining its previous
    /// workspace.
    func resetForReuse() {
        guard item != nil || actions != nil || editField != nil else { return }
        editField?.removeFromSuperview()
        editField = nil
        editFieldBridge = nil
        editingItemId = nil
        isEditing = false
        item = nil
        model = nil
        actions = nil
        checkbox.onClick = nil
        removeButton.onClick = nil
        removeButton.isHidden = true
        textClickOverlay.onClick = nil
        textLabel.stringValue = ""
        attachmentButton.resetForReuse()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let item, let actions else { return super.menu(for: event) }
        let menu = NSMenu()
        menu.autoenablesItems = false
        // Freeze the workspace-bound closure at build time: NSMenu tracking
        // allows this pooled line to be recycled before the selection fires.
        menu.addItem(SidebarRowClosureMenuItem(
            title: String(localized: "sidebar.checklist.editItem", defaultValue: "Edit")
        ) { [beginEdit = actions.onBeginChecklistItemEdit] in
            beginEdit(item.id)
        })
        if item.state != .inProgress {
            menu.addItem(SidebarRowClosureMenuItem(
                title: String(localized: "sidebar.checklist.markInProgress", defaultValue: "Mark In Progress")
            ) { [actions] in
                actions.checklistSetItemState(item.id, .inProgress)
            })
        }
        menu.addItem(SidebarRowClosureMenuItem(
            title: String(localized: "sidebar.checklist.removeItem", defaultValue: "Remove")
        ) { [actions] in
            actions.checklistRemoveItem(item.id)
        })
        return menu
    }
}

// MARK: - Add row

/// The trailing add affordance under the inline expansion: a ghost
/// "+ Add item" row that arms into a `plus.circle` + focused text field.
/// Enter commits and re-arms a fresh empty field; Esc dismisses.
@MainActor
final class SidebarRowChecklistAddRow: NSView {
    private let ghostButton = SidebarRowChecklistGhostAddButton()
    private let plusIconView = NSImageView()
    private var addField: FocusGrabbingTextField?
    private var addFieldBridge: SidebarRowChecklistFieldBridge?
    private var lastArmToken = 0
    private var lastArmWorkspaceId: UUID?
    private var isAdding = false
    private var model: SidebarWorkspaceRowModel?
    private var primary: NSColor = .labelColor
    private var onCommit: ((String) -> Void)?
    private var onCancel: (() -> Void)?

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(ghostButton)
        plusIconView.imageScaling = .scaleProportionallyDown
        plusIconView.isHidden = true
        addSubview(plusIconView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        workspaceId: UUID,
        model: SidebarWorkspaceRowModel,
        secondary: NSColor,
        primary: NSColor,
        isAdding: Bool,
        armToken: Int,
        onBeginAdding: @escaping () -> Void,
        onCommit: @escaping (String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.model = model
        self.primary = primary
        self.onCommit = onCommit
        self.onCancel = onCancel
        self.isAdding = isAdding

        ghostButton.isHidden = isAdding
        if !isAdding {
            // A `plus` glyph plus "Add item" (legacy ghost row: the add row
            // never reads as a real unchecked item).
            ghostButton.configure(
                iconPointSize: model.scaled(7),
                title: String(localized: "sidebar.checklist.addItem", defaultValue: "Add item"),
                font: .systemFont(ofSize: model.scaled(10)),
                color: secondary,
                onClick: onBeginAdding
            )
        }

        plusIconView.isHidden = !isAdding
        if isAdding {
            plusIconView.image = RenderableSystemSymbol.configuredAppKitImage(
                systemName: "plus.circle", pointSize: model.scaled(8), weight: nil
            )
            plusIconView.contentTintColor = secondary
            // Key the armed editor by workspace AND token: per-workspace
            // tokens commonly collide (both start at 1), and a recycled cell
            // must never keep the previous workspace's draft or bridge.
            if addField == nil || armToken != lastArmToken || workspaceId != lastArmWorkspaceId {
                rearmField()
            }
        } else {
            teardownField()
        }
        lastArmToken = armToken
        lastArmWorkspaceId = workspaceId
        needsLayout = true
    }

    /// Reuse teardown: drop the editor and every workspace-bound closure so
    /// a hidden pooled row stops retaining its previous workspace.
    func resetForReuse() {
        guard onCommit != nil || onCancel != nil || addField != nil else { return }
        // Ordering: disarm FIRST so the teardown-triggered focus-loss commit
        // cannot re-arm mid-reset.
        isAdding = false
        teardownField()
        onCommit = nil
        onCancel = nil
        model = nil
        lastArmToken = 0
        lastArmWorkspaceId = nil
    }

    /// Creates a fresh, empty, focus-grabbing add field (legacy bumps the
    /// field's view identity on every arm/commit for the same effect).
    func rearmField() {
        guard let model else { return }
        addField?.removeFromSuperview()
        let field = FocusGrabbingTextField(string: "")
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.cell?.usesSingleLineMode = true
        field.lineBreakMode = .byTruncatingTail
        field.font = .systemFont(ofSize: 11 * model.fontScale)
        field.textColor = primary
        field.caretColor = primary
        field.placeholderString = String(
            localized: "sidebar.checklist.addItemPlaceholder",
            defaultValue: "New checklist item"
        )
        field.setAccessibilityLabel(field.placeholderString ?? "")
        field.setAccessibilityIdentifier("SidebarChecklistAddItemField")
        // Capture the closure VALUES at field-creation time: this pooled
        // row's stored onCommit/onCancel are replaced when the cell is
        // reused for another workspace, and the OLD editor's
        // teardown-triggered focus-loss commit must go to the workspace
        // that armed it (the stored closures are workspace-bound and free
        // of section-state dereferences).
        guard let commit = onCommit, let cancel = onCancel else { return }
        let bridge = SidebarRowChecklistFieldBridge(
            onCommit: { text in
                commit(text)
            },
            onCancel: {
                cancel()
            }
        )
        // Legacy `commitInlineAdd`: an ENTER commit re-arms a fresh, focused,
        // empty add field. Focus-loss commits (teardown, replacement) never
        // re-arm — a synchronous re-arm inside removeFromSuperview would
        // strand an untracked editor.
        bridge.onReturnCommit = { [weak self] in
            self?.rearmFieldIfStillAdding()
        }
        // A focus-loss commit keeps the field armed (legacy parity) but must
        // not keep the submitted draft — a later Return would add it twice.
        bridge.onEndEditingCommit = { [weak field] in
            field?.stringValue = ""
        }
        field.delegate = bridge
        addFieldBridge = bridge
        addField = field
        // Valid frame BEFORE the window attach: the focus grab installs the
        // field editor immediately, and an editor set up against a zero
        // frame draws an oversized dark box over the row.
        field.frame = plannedFieldFrame()
        addSubview(field)
        SidebarRowChecklistFieldBridge.clearFieldEditorBackground(field)
        needsLayout = true
    }

    private func plannedFieldFrame() -> NSRect {
        guard let model else { return NSRect(x: 0, y: 0, width: 100, height: 17) }
        let iconWidth = plusIconView.image?.size.width ?? 0
        let fieldHeight = 11 * model.fontScale + 4
        let fieldX = iconWidth + 4
        return NSRect(
            x: fieldX, y: max(0, (bounds.height - fieldHeight) / 2),
            width: max(10, bounds.width - fieldX), height: fieldHeight
        )
    }

    private func rearmFieldIfStillAdding() {
        guard isAdding else { return }
        rearmField()
    }

    private func teardownField() {
        addField?.removeFromSuperview()
        addField = nil
        addFieldBridge = nil
    }

    func measuredHeight(width: CGFloat) -> CGFloat {
        guard let model else { return 0 }
        if isAdding {
            let iconHeight = plusIconView.image?.size.height ?? 0
            return ceil(max(11 * model.fontScale + 4, iconHeight))
        }
        return ghostButton.measuredHeight()
    }

    override func layout() {
        super.layout()
        guard let model else { return }
        if isAdding, let addField {
            let iconSize = plusIconView.image?.size ?? .zero
            plusIconView.frame = NSRect(
                x: 0, y: (bounds.height - iconSize.height) / 2,
                width: iconSize.width, height: iconSize.height
            )
            let fieldHeight = 11 * model.fontScale + 4
            let fieldX = iconSize.width + 4
            addField.frame = NSRect(
                x: fieldX, y: (bounds.height - fieldHeight) / 2,
                width: max(10, bounds.width - fieldX), height: fieldHeight
            )
        } else {
            ghostButton.frame = NSRect(
                x: 0, y: 0,
                width: min(ghostButton.measuredWidth(), bounds.width),
                height: bounds.height
            )
        }
    }
}

/// The ghost "+ Add item" button (icon + label, single click target).
@MainActor
final class SidebarRowChecklistGhostAddButton: NSControl {
    private let iconView = NSImageView()
    private let label = SidebarRowTextView(lines: 1)
    private var onClick: (() -> Void)?

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        iconView.imageScaling = .scaleProportionallyDown
        addSubview(iconView)
        addSubview(label)
        setAccessibilityRole(.button)
        setAccessibilityIdentifier("SidebarChecklistAddItemRow")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        iconPointSize: CGFloat,
        title: String,
        font: NSFont,
        color: NSColor,
        onClick: @escaping () -> Void
    ) {
        self.onClick = onClick
        iconView.image = RenderableSystemSymbol.configuredAppKitImage(
            systemName: "plus", pointSize: iconPointSize, weight: nil
        )
        iconView.contentTintColor = color
        label.stringValue = title
        label.font = font
        label.textColor = color
        needsLayout = true
    }

    func measuredWidth() -> CGFloat {
        let iconWidth = iconView.image?.size.width ?? 0
        return ceil(iconWidth + 4 + label.sidebarNaturalCellSize.width)
    }

    func measuredHeight() -> CGFloat {
        let iconHeight = iconView.image?.size.height ?? 0
        return ceil(max(iconHeight, label.sidebarNaturalCellSize.height))
    }

    override func layout() {
        super.layout()
        let iconSize = iconView.image?.size ?? .zero
        iconView.frame = NSRect(
            x: 0, y: (bounds.height - iconSize.height) / 2,
            width: iconSize.width, height: iconSize.height
        )
        let labelSize = label.sidebarNaturalCellSize
        label.frame = NSRect(
            x: iconSize.width + 4, y: (bounds.height - labelSize.height) / 2,
            width: max(0, bounds.width - iconSize.width - 4), height: labelSize.height
        )
    }

    override func mouseDown(with event: NSEvent) {
        // Swallow so the table row action does not also fire; dim while
        // pressed like the SwiftUI plain Button this ports.
        alphaValue = SidebarRowPressedDim.pressedAlpha
    }

    override func mouseUp(with event: NSEvent) {
        alphaValue = 1
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return }
        onClick?()
    }

    /// VoiceOver/keyboard activation parity with the legacy SwiftUI Button.
    override func accessibilityPerformPress() -> Bool {
        guard let onClick else { return false }
        onClick()
        return true
    }
}

// MARK: - Attachment menu button

/// The always-visible paperclip (+ count) that manages a checklist item's
/// image attachments through a menu: Attach Images…, then per-attachment
/// Open / Remove Attachment submenus.
@MainActor
final class SidebarRowChecklistAttachmentButton: NSControl {
    private let iconView = NSImageView()
    private let countLabel = SidebarRowTextView(lines: 1)
    /// The borderless-menu disclosure chevron SwiftUI's
    /// `.menuStyle(.borderlessButton)` renders after the label.
    private let chevronView = NSImageView()
    private var item: WorkspaceChecklistItem?
    private var actions: SidebarAppKitRowActions?
    private var iconPointSize: CGFloat = 9

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        iconView.imageScaling = .scaleProportionallyDown
        addSubview(iconView)
        countLabel.isHidden = true
        addSubview(countLabel)
        chevronView.imageScaling = .scaleProportionallyDown
        addSubview(chevronView)
        setAccessibilityRole(.button)
        setAccessibilityIdentifier("WorkspaceChecklistAttachmentMenu")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func resetForReuse() {
        item = nil
        actions = nil
    }

    func configure(
        item: WorkspaceChecklistItem,
        model: SidebarWorkspaceRowModel,
        color: NSColor,
        actions: SidebarAppKitRowActions
    ) {
        self.item = item
        self.actions = actions
        // Legacy passes `iconPointSize: 9 * fontScale` (no magnification).
        iconPointSize = 9 * model.fontScale
        iconView.image = RenderableSystemSymbol.configuredAppKitImage(
            systemName: "paperclip", pointSize: iconPointSize, weight: nil
        )
        iconView.contentTintColor = color
        chevronView.image = RenderableSystemSymbol.configuredAppKitImage(
            systemName: "chevron.down", pointSize: iconPointSize * 0.65, weight: .semibold
        )
        chevronView.contentTintColor = color
        countLabel.isHidden = item.attachmentCount == 0
        if item.attachmentCount > 0 {
            countLabel.stringValue = "\(item.attachmentCount)"
            countLabel.font = .monospacedDigitSystemFont(ofSize: model.scaled(10), weight: .regular)
            countLabel.textColor = color
        }
        toolTip = String(localized: "sidebar.checklist.attachmentsTooltip", defaultValue: "Manage images")
        setAccessibilityLabel(accessibilityText(count: item.attachmentCount))
        needsLayout = true
    }

    private func accessibilityText(count: Int) -> String {
        switch count {
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
                Int64(count)
            )
        }
    }

    /// Legacy footprint: the borderless-menu chevron packs INSIDE the
    /// `minWidth = iconPointSize + 8` slot next to the paperclip, so the
    /// whole control stays ~17pt wide and item text wraps at the same
    /// width as the SwiftUI row.
    func measuredSize() -> NSSize {
        let iconSize = iconView.image?.size ?? .zero
        let chevronSize = chevronView.image?.size ?? .zero
        var width = iconSize.width + (chevronSize.width > 0 ? chevronSize.width + 2 : 0)
        var height = max(iconSize.height, chevronSize.height)
        if !countLabel.isHidden {
            let countSize = countLabel.sidebarNaturalCellSize
            width += 2 + ceil(countSize.width)
            // The count uses the magnified item font, which can exceed the
            // un-magnified icon slot at large accessibility magnifications.
            height = max(height, ceil(countSize.height))
        }
        return NSSize(
            width: max(width, iconPointSize + 8),
            height: max(height, iconPointSize + 8)
        )
    }

    override func layout() {
        super.layout()
        let iconSize = iconView.image?.size ?? .zero
        let countSize = countLabel.isHidden ? NSSize.zero : countLabel.sidebarNaturalCellSize
        let chevronSize = chevronView.image?.size ?? .zero
        let labelWidth = iconSize.width + (countLabel.isHidden ? 0 : 2 + ceil(countSize.width))
        let contentWidth = labelWidth + (chevronSize.width > 0 ? chevronSize.width + 2 : 0)
        var x = (bounds.width - contentWidth) / 2
        iconView.frame = NSRect(
            x: x, y: (bounds.height - iconSize.height) / 2,
            width: iconSize.width, height: iconSize.height
        )
        x += iconSize.width + 2
        if !countLabel.isHidden {
            countLabel.frame = NSRect(
                x: x, y: (bounds.height - countSize.height) / 2,
                width: ceil(countSize.width), height: countSize.height
            )
            x += ceil(countSize.width) + 2
        }
        chevronView.frame = NSRect(
            x: x, y: (bounds.height - chevronSize.height) / 2,
            width: chevronSize.width, height: chevronSize.height
        )
    }

    override func mouseDown(with event: NSEvent) {
        presentAttachmentsMenu()
    }

    /// VoiceOver/keyboard activation parity with the legacy SwiftUI Menu.
    override func accessibilityPerformPress() -> Bool {
        guard item != nil, actions != nil else { return false }
        presentAttachmentsMenu()
        return true
    }

    private func presentAttachmentsMenu() {
        guard let item, let actions else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(SidebarRowClosureMenuItem(
            title: String(localized: "sidebar.checklist.attachImages", defaultValue: "Attach Images…")
        ) { [actions] in
            actions.checklistAddAttachments(item.id)
        })
        if !item.attachments.isEmpty {
            menu.addItem(.separator())
            for attachment in item.attachments {
                let submenu = NSMenu()
                submenu.autoenablesItems = false
                submenu.addItem(SidebarRowClosureMenuItem(
                    title: String(localized: "sidebar.checklist.openAttachment", defaultValue: "Open")
                ) { [actions] in
                    actions.checklistOpenAttachments(item.id, attachment.id)
                })
                submenu.addItem(SidebarRowClosureMenuItem(
                    title: String(
                        localized: "sidebar.checklist.removeAttachment",
                        defaultValue: "Remove Attachment"
                    )
                ) { [actions] in
                    actions.checklistRemoveAttachment(item.id, attachment.id)
                })
                let parent = NSMenuItem(title: attachment.displayName, action: nil, keyEquivalent: "")
                parent.submenu = submenu
                menu.addItem(parent)
            }
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height + 2), in: self)
    }
}

// MARK: - Support

/// Transparent full-frame click target (the tap-to-edit overlay on item
/// text; legacy: `.contentShape(Rectangle()).onTapGesture`).
@MainActor
final class SidebarRowChecklistTransparentButton: NSControl {
    var onClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        // Swallow so the table row action does not also fire.
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return }
        onClick?()
    }

    /// VoiceOver/keyboard activation parity with the legacy SwiftUI Button.
    override func accessibilityPerformPress() -> Bool {
        guard let onClick else { return false }
        onClick()
        return true
    }
}

/// Bridges Return / Escape / focus loss on a checklist field to commit and
/// cancel closures — the exact `ChecklistInputField.Coordinator` semantics
/// (focus loss commits non-empty text, Option-Return inserts a newline).
@MainActor
final class SidebarRowChecklistFieldBridge: NSObject, NSTextFieldDelegate {
    private let onCommit: (String) -> Void
    private let onCancel: () -> Void
    /// Invoked ONLY for an explicit Return commit — never for the focus-loss
    /// commit that fires while a field is being torn down or replaced, where
    /// a synchronous re-arm would re-enter the teardown and strand an
    /// untracked editor in the row.
    var onReturnCommit: (() -> Void)?
    /// Invoked after a focus-loss (end-editing) commit. The add field uses
    /// this to clear its committed draft: legacy re-created an empty field
    /// here, and keeping the submitted text armed would double-add it on a
    /// later Return.
    var onEndEditingCommit: (() -> Void)?
    private var committed = false

    init(onCommit: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        self.onCommit = onCommit
        self.onCancel = onCancel
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertLineBreak(_:))
            || selector == #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)) {
            textView.insertText("\n", replacementRange: textView.selectedRange())
            control.stringValue = textView.string
            return true
        }
        if selector == #selector(NSResponder.insertNewline(_:)) {
            committed = true
            onCommit(control.stringValue)
            onReturnCommit?()
            return true
        }
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            committed = true
            onCancel()
            return true
        }
        return false
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard !committed else { return }
        committed = true
        let text = (obj.object as? NSTextField)?.stringValue ?? ""
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            onCancel()
        } else {
            onCommit(text)
            if let onEndEditingCommit {
                onEndEditingCommit()
                // Add-field sessions persist across focus losses (the field
                // stays armed, legacy parity) — re-open the latch so the
                // NEXT focus/type/click-away commit is not silently dropped.
                // Edit-field bridges never set onEndEditingCommit and stay
                // latched (their session ends with the commit).
                committed = false
            }
        }
    }

    /// Legacy parity: the checklist fields draw no background — the focused
    /// field editor otherwise paints a dark box over the (blue) row.
    static func clearFieldEditorBackground(_ field: NSTextField) {
        guard let editor = field.currentEditor() as? NSTextView else { return }
        editor.drawsBackground = false
        editor.enclosingScrollView?.drawsBackground = false
    }
}

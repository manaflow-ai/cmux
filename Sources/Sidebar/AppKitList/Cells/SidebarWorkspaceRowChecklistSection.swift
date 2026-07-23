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
    /// Every input the expensive item-line reconciliation depends on: the
    /// cell re-applies its model on hover repaints, optimistic selection
    /// paints, and 40ms pump ticks, and rebuilding up to 50 attributed item
    /// lines per unrelated event is hot-path fanout.
    private struct ConfigureKey: Equatable {
        let workspaceId: UUID
        let items: [WorkspaceChecklistItem]
        let title: String
        let completedCount: Int
        let totalCount: Int
        let firstUncheckedText: String?
        let isActive: Bool
        let isMultiSelected: Bool
        let colorSchemeIsDark: Bool
        let settings: SidebarTabItemSettingsSnapshot
        let magnificationPercent: Int
        let isExpanded: Bool
        let token: Int
        let popoverPresented: Bool
        let editingItemId: UUID?
        let todoControlsEnabled: Bool
    }

    private var lastConfigureKey: ConfigureKey?

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
        let key = ConfigureKey(
            workspaceId: model.workspaceId,
            items: model.snapshot.checklistItems,
            title: model.snapshot.title,
            completedCount: model.snapshot.checklistCompletedCount,
            totalCount: model.snapshot.checklistTotalCount,
            firstUncheckedText: model.snapshot.checklistFirstUncheckedText,
            isActive: model.isActive,
            isMultiSelected: model.isMultiSelected,
            colorSchemeIsDark: model.colorSchemeIsDark,
            settings: model.settings,
            magnificationPercent: model.globalFontMagnificationPercent,
            isExpanded: model.isChecklistExpanded,
            token: model.checklistAddFieldActivationToken,
            popoverPresented: model.isChecklistPopoverPresented,
            editingItemId: model.editingChecklistItemId,
            todoControlsEnabled: model.todoControlsEnabled
        )
        if key == lastConfigureKey {
            // Unrelated churn (hover, optimistic paint, pump tick): nothing
            // this section renders changed. Keep the popover reconcile — it
            // guards on its own model — and skip the line rebuild.
            reconcileChecklistPopover(model: model, actions: actions)
            return
        }
        lastConfigureKey = key
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
            lastConfigureKey = nil
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
                    guard let model = self?.model,
                          let tabManager = self?.actions?.commands.tabManager else { return }
                    // Arm via the same activation-token path the context menu
                    // uses, so the armed field is part of the row model and
                    // the prototype height measurement sees it.
                    WorkspaceTodoActions.requestChecklistAddField(
                        workspaceId: model.workspaceId,
                        in: tabManager
                    )
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
        guard window != nil else {
            // Detached without a configure pass (workspace deleted, row
            // unmounted, cell enqueued for reuse): the legacy host's
            // dismantle closes the popover and writes presentation state
            // back; leaving it armed re-presented on the row's return and
            // kept actions targeting an unmounted row alive.
            if popoverPresenter.isShown {
                popoverPresenter.close()
                activePopoverDismissContext?()
            }
            activePopoverDismissContext = nil
            awaitingPopoverDismissAck = false
            lastAddFieldToken = 0
            lastPopoverModel = nil
            pendingPopoverPresentation = false
            lastConfigureKey = nil
            return
        }
        if pendingPopoverPresentation {
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
        // Same latch as the external-dismiss path: the container's
        // `presented = false` write lands asynchronously, and a stale
        // configure tick in between must not re-present the popover the
        // user just closed.
        awaitingPopoverDismissAck = true
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

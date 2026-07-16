import AppKit
import CmuxSettings
import CmuxWorkspaces
import Foundation

/// The checklist block under a workspace row: progress summary line plus
/// either the inline expansion or an anchored popover, mirroring
/// `SidebarWorkspaceChecklistSection`. Inline add/edit state lives in
/// `SidebarWorkspaceCellTransientState` (it changes row height, so the sizing
/// cell must see it too).
final class SidebarWorkspaceCellChecklistSection: NSView {
    private static let visibleRowCount = 6
    private static let rowSpacing: CGFloat = 2

    private let column = SidebarWorkspaceCellStackFactory.vertical(spacing: 2, alignment: .width)

    private let summaryButton = SidebarWorkspaceCellButton()
    private let summaryRow = SidebarWorkspaceCellStackFactory.horizontal(spacing: 4)
    private let summaryIcon = SidebarWorkspaceCellIconView()
    private let summaryCountLabel = SidebarWorkspaceCellLabel()
    private let summaryDotLabel = SidebarWorkspaceCellLabel()
    private let summaryTextLabel = SidebarWorkspaceCellLabel()
    private let summarySpacer = NSView()
    private let summaryContainer = NSView()

    private let expandedColumn = SidebarWorkspaceCellStackFactory.vertical(spacing: 2, alignment: .width)
    private let scrollView = NSScrollView()
    private let itemsStack = SidebarWorkspaceCellStackFactory.vertical(spacing: 2, alignment: .width)
    private let itemsPool = SidebarWorkspaceCellRowPool<SidebarWorkspaceCellChecklistItemRowView>()
    private lazy var scrollHeight = scrollView.heightAnchor.constraint(equalToConstant: 0)

    private let addRow = SidebarWorkspaceCellStackFactory.horizontal(spacing: 4)
    private let addIcon = SidebarWorkspaceCellIconView()
    private var addField: FocusGrabbingTextField?
    private let addFieldContainer = NSView()
    private let addGhostButton = SidebarWorkspaceCellButton()

    private let popoverController = SidebarWorkspaceCellChecklistPopoverController()

    private var workspaceId: UUID?
    private var lastConsumedActivationToken = 0
    private var context: SidebarWorkspaceCellContext?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false

        summaryCountLabel.setContentHuggingPriority(.required, for: .horizontal)
        summaryCountLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        summaryDotLabel.setContentHuggingPriority(.required, for: .horizontal)
        summaryTextLabel.setContentHuggingPriority(.required, for: .horizontal)
        summarySpacer.translatesAutoresizingMaskIntoConstraints = false
        summarySpacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        summaryRow.addArrangedSubview(summaryIcon)
        summaryRow.addArrangedSubview(summaryCountLabel)
        summaryRow.addArrangedSubview(summaryDotLabel)
        summaryRow.addArrangedSubview(summaryTextLabel)
        summaryRow.addArrangedSubview(summarySpacer)

        summaryContainer.translatesAutoresizingMaskIntoConstraints = false
        summaryContainer.addSubview(summaryRow)
        summaryButton.imagePosition = .noImage
        summaryButton.title = ""
        summaryButton.setAccessibilityIdentifier("SidebarChecklistSummaryLine")
        summaryButton.onPress = { [weak self] in self?.summaryTapped() }
        summaryContainer.addSubview(summaryButton)
        NSLayoutConstraint.activate([
            summaryRow.leadingAnchor.constraint(equalTo: summaryContainer.leadingAnchor),
            summaryRow.trailingAnchor.constraint(equalTo: summaryContainer.trailingAnchor),
            summaryRow.topAnchor.constraint(equalTo: summaryContainer.topAnchor),
            summaryRow.bottomAnchor.constraint(equalTo: summaryContainer.bottomAnchor),
            summaryButton.leadingAnchor.constraint(equalTo: summaryContainer.leadingAnchor),
            summaryButton.trailingAnchor.constraint(equalTo: summaryContainer.trailingAnchor),
            summaryButton.topAnchor.constraint(equalTo: summaryContainer.topAnchor),
            summaryButton.bottomAnchor.constraint(equalTo: summaryContainer.bottomAnchor),
        ])

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.verticalScrollElasticity = .none
        let documentView = SidebarWorkspaceCellFlippedView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(itemsStack)
        NSLayoutConstraint.activate([
            itemsStack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            itemsStack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
            itemsStack.topAnchor.constraint(equalTo: documentView.topAnchor),
            itemsStack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor),
        ])
        scrollView.documentView = documentView
        NSLayoutConstraint.activate([
            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
        ])
        scrollHeight.isActive = true

        addFieldContainer.translatesAutoresizingMaskIntoConstraints = false
        addGhostButton.imagePosition = .noImage
        addGhostButton.setAccessibilityIdentifier("SidebarChecklistAddItemRow")
        addGhostButton.onPress = { [weak self] in self?.addRowTapped() }
        addRow.addArrangedSubview(addIcon)
        addRow.addArrangedSubview(addFieldContainer)
        addRow.addArrangedSubview(addGhostButton)

        expandedColumn.edgeInsets = NSEdgeInsets(top: 0, left: 2, bottom: 0, right: 0)
        expandedColumn.addArrangedSubview(scrollView)
        expandedColumn.addArrangedSubview(addRow)

        column.addArrangedSubview(summaryContainer)
        column.addArrangedSubview(expandedColumn)
        addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
            column.topAnchor.constraint(equalTo: topAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }

    func update(_ context: SidebarWorkspaceCellContext) {
        self.context = context
        let snapshot = context.snapshot
        let workspace = context.workspace
        let visible = !workspace.checklistItems.isEmpty
            || snapshot.checklistAddFieldActivationToken > 0
            || snapshot.isChecklistPopoverPresented
        guard visible else {
            isHidden = true
            popoverController.dismiss()
            return
        }
        isHidden = false
        if workspaceId != snapshot.workspaceId {
            lastConsumedActivationToken = 0
        }
        workspaceId = snapshot.workspaceId

        let usesPopover = context.settings.workspaceTodoChecklistStyle == .popover
        var state = SidebarWorkspaceCellTransientState.shared.state(for: snapshot.workspaceId)

        // A pending "Add Checklist Item…" activation arms the inline add field
        // (popover style routes it into the popover instead).
        if !usesPopover,
           snapshot.checklistAddFieldActivationToken > 0,
           snapshot.checklistAddFieldActivationToken != lastConsumedActivationToken,
           !state.checklistInlineAddActive {
            lastConsumedActivationToken = snapshot.checklistAddFieldActivationToken
            state.checklistInlineAddActive = true
            SidebarWorkspaceCellTransientState.shared.update(snapshot.workspaceId) {
                $0.checklistInlineAddActive = true
            }
        }

        updateSummary(context, usesPopover: usesPopover)

        let showsExpansion = !usesPopover
            && (snapshot.isChecklistExpanded || workspace.checklistTotalCount == 0)
        expandedColumn.isHidden = !showsExpansion
        if showsExpansion {
            updateExpandedList(context, state: state)
        }

        if context.actions != nil {
            popoverController.sync(context: context, anchor: self, usesPopover: usesPopover)
        }
    }

    private func updateSummary(_ context: SidebarWorkspaceCellContext, usesPopover: Bool) {
        let style = context.style
        let workspace = context.workspace
        summaryContainer.isHidden = workspace.checklistTotalCount == 0
        guard workspace.checklistTotalCount > 0 else { return }
        let completed = workspace.checklistCompletedCount
        let total = workspace.checklistTotalCount
        summaryIcon.setSymbol(
            completed == total ? "checkmark.circle.fill" : "checklist",
            pointSize: style.fontSize(8),
            color: style.secondary(0.65)
        )
        summaryCountLabel.font = SidebarWorkspaceCellFonts.monospacedDigit(style.fontSize(10), weight: .semibold)
        summaryCountLabel.textColor = style.secondary(0.9)
        summaryCountLabel.stringValue = "\(completed)/\(total)"
        summaryDotLabel.isHidden = workspace.checklistFirstUncheckedText == nil
        summaryTextLabel.isHidden = workspace.checklistFirstUncheckedText == nil
        if let firstUnchecked = workspace.checklistFirstUncheckedText {
            summaryDotLabel.font = SidebarWorkspaceCellFonts.monospacedDigit(style.fontSize(10), weight: .semibold)
            summaryDotLabel.textColor = style.secondary(0.65)
            summaryDotLabel.stringValue = "·"
            summaryTextLabel.font = SidebarWorkspaceCellFonts.system(style.fontSize(10))
            summaryTextLabel.textColor = style.secondary(0.65)
            summaryTextLabel.stringValue = firstUnchecked
        }
        summaryButton.toolTip = usesPopover
            ? String(localized: "sidebar.checklist.popoverTooltip", defaultValue: "Show checklist")
            : (context.snapshot.isChecklistExpanded
                ? String(localized: "sidebar.checklist.collapseTooltip", defaultValue: "Hide checklist items")
                : String(localized: "sidebar.checklist.expandTooltip", defaultValue: "Show checklist items"))
    }

    private func updateExpandedList(
        _ context: SidebarWorkspaceCellContext,
        state: SidebarWorkspaceCellTransientState.State
    ) {
        let style = context.style
        let ordered = SidebarWorkspaceChecklistDisplayPolicy.orderedItems(context.workspace.checklistItems)

        scrollView.isHidden = ordered.isEmpty
        if !ordered.isEmpty {
            let rowHeight = 11 * style.fontScale + 4
            let visibleCount = min(ordered.count, Self.visibleRowCount)
            scrollHeight.constant = rowHeight * CGFloat(visibleCount)
                + Self.rowSpacing * CGFloat(visibleCount - 1)
            let rows = itemsPool.prepare(count: ordered.count, in: itemsStack) {
                SidebarWorkspaceCellChecklistItemRowView()
            }
            let appearance = SidebarWorkspaceCellChecklistItemRowView.Appearance(
                checkboxPointSize: style.fontSize(8),
                removePointSize: style.fontSize(9),
                textFont: SidebarWorkspaceCellFonts.system(style.fontSize(10)),
                editFontSize: 11 * style.fontScale,
                primaryColor: style.secondary(0.9),
                secondaryColor: style.secondary(0.65)
            )
            let actions = context.actions
            let workspaceId = context.snapshot.workspaceId
            for (item, row) in zip(ordered, rows) {
                row.update(
                    item: item,
                    appearance: appearance,
                    isEditing: state.checklistEditingItemId == item.id,
                    setState: { itemId, itemState in actions?.checklist.setItemState(itemId, itemState) },
                    remove: { itemId in actions?.checklist.removeItem(itemId) },
                    beginEdit: { itemId in
                        SidebarWorkspaceCellTransientState.shared.update(workspaceId) {
                            $0.checklistEditingItemId = itemId
                        }
                    },
                    finishEdit: { itemId, text in
                        SidebarWorkspaceCellTransientState.shared.update(workspaceId) {
                            $0.checklistEditingItemId = nil
                        }
                        if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            actions?.checklist.editItem(itemId, text)
                        }
                    }
                )
            }
        }

        updateAddRow(context, state: state)
    }

    private func updateAddRow(
        _ context: SidebarWorkspaceCellContext,
        state: SidebarWorkspaceCellTransientState.State
    ) {
        let style = context.style
        if state.checklistInlineAddActive {
            addIcon.setSymbol("plus.circle", pointSize: style.fontSize(8), color: style.secondary(0.65))
            addGhostButton.isHidden = true
            addFieldContainer.isHidden = false
            installAddFieldIfNeeded(context)
        } else {
            removeAddField()
            addFieldContainer.isHidden = true
            addGhostButton.isHidden = false
            addIcon.setSymbol("plus", pointSize: style.fontSize(7), color: style.secondary(0.65))
            addGhostButton.attributedTitle = NSAttributedString(
                string: String(localized: "sidebar.checklist.addItem", defaultValue: "Add item"),
                attributes: [
                    .font: SidebarWorkspaceCellFonts.system(style.fontSize(10)),
                    .foregroundColor: style.secondary(0.65),
                ]
            )
        }
    }

    private func installAddFieldIfNeeded(_ context: SidebarWorkspaceCellContext) {
        guard addField == nil else { return }
        let style = context.style
        let field = FocusGrabbingTextField(string: "")
        field.translatesAutoresizingMaskIntoConstraints = false
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.cell?.usesSingleLineMode = true
        field.lineBreakMode = .byTruncatingTail
        field.font = SidebarWorkspaceCellFonts.system(11 * style.fontScale)
        field.textColor = style.secondary(0.9)
        field.caretColor = style.secondary(0.9)
        field.placeholderString = String(
            localized: "sidebar.checklist.addItemPlaceholder",
            defaultValue: "New checklist item"
        )
        field.setAccessibilityIdentifier("SidebarChecklistAddItemField")
        let coordinator = ChecklistInputField.Coordinator(
            onCommit: { [weak self] text in self?.commitInlineAdd(text) },
            onCancel: { [weak self] in self?.cancelInlineAdd() }
        )
        field.delegate = coordinator
        addFieldCoordinator = coordinator
        addField = field
        addFieldContainer.addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: addFieldContainer.leadingAnchor),
            field.trailingAnchor.constraint(equalTo: addFieldContainer.trailingAnchor),
            field.topAnchor.constraint(equalTo: addFieldContainer.topAnchor),
            field.bottomAnchor.constraint(equalTo: addFieldContainer.bottomAnchor),
            field.heightAnchor.constraint(equalToConstant: 11 * style.fontScale + 4),
        ])
    }

    private var addFieldCoordinator: ChecklistInputField.Coordinator?

    private func removeAddField() {
        guard let field = addField else { return }
        field.delegate = nil
        field.removeFromSuperview()
        addField = nil
        addFieldCoordinator = nil
    }

    /// Enter (or focus loss) commits the trimmed text and re-arms a fresh
    /// focused field for the next item.
    private func commitInlineAdd(_ text: String) {
        guard let workspaceId, let context else { return }
        removeAddField()
        context.actions?.onConsumeChecklistAddFieldActivation()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            context.actions?.checklist.addItem(text)
        }
        // Re-arm: recreating the field re-focuses and clears it.
        SidebarWorkspaceCellTransientState.shared.update(workspaceId) {
            $0.checklistInlineAddActive = !trimmed.isEmpty
        }
    }

    private func cancelInlineAdd() {
        guard let workspaceId, let context else { return }
        removeAddField()
        context.actions?.onConsumeChecklistAddFieldActivation()
        SidebarWorkspaceCellTransientState.shared.update(workspaceId) {
            $0.checklistInlineAddActive = false
        }
    }

    private func summaryTapped() {
        guard let context, let actions = context.actions else { return }
        if context.settings.workspaceTodoChecklistStyle == .popover {
            actions.onChecklistPopoverPresentedChange(!context.snapshot.isChecklistPopoverPresented)
        } else {
            actions.onToggleChecklistExpansion()
        }
    }

    private func addRowTapped() {
        guard let context, let workspaceId else { return }
        if context.settings.workspaceTodoChecklistStyle == .popover {
            context.actions?.onChecklistPopoverPresentedChange(
                !context.snapshot.isChecklistPopoverPresented
            )
        } else {
            SidebarWorkspaceCellTransientState.shared.update(workspaceId) {
                $0.checklistInlineAddActive = true
            }
        }
    }

    /// Closes the popover without invoking callbacks (cell reuse/teardown).
    func dismissPopover() {
        popoverController.dismiss()
    }
}

/// Flipped document view so the checklist scroll content grows downward.
final class SidebarWorkspaceCellFlippedView: NSView {
    override var isFlipped: Bool { true }
}

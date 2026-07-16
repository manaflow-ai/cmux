import AppKit
import CmuxWorkspaces
import Foundation

/// Owns the NSPopover for the `popover` checklist style: presents/dismisses
/// against `snapshot.isChecklistPopoverPresented` and reports user closes
/// through `actions.onChecklistPopoverPresentedChange`, mirroring the SwiftUI
/// `ChecklistSummaryPopoverModifier` binding.
@MainActor
final class SidebarWorkspaceCellChecklistPopoverController: NSObject, NSPopoverDelegate {
    private var popover: NSPopover?
    private var contentView: SidebarWorkspaceCellChecklistPopoverView?
    private var onUserClose: (() -> Void)?
    private var isDismissingProgrammatically = false

    func sync(context: SidebarWorkspaceCellContext, anchor: NSView, usesPopover: Bool) {
        guard usesPopover, context.snapshot.isChecklistPopoverPresented, let actions = context.actions else {
            dismiss()
            return
        }
        onUserClose = {
            actions.onChecklistPopoverPresentedChange(false)
            // Any close consumes a pending add-field activation so a dismissed
            // first-item popover does not leave stale "add requested" state.
            actions.onConsumeChecklistAddFieldActivation()
        }
        if popover == nil {
            let content = SidebarWorkspaceCellChecklistPopoverView()
            let controller = NSViewController()
            controller.view = content
            let popover = NSPopover()
            popover.behavior = .transient
            popover.delegate = self
            popover.contentViewController = controller
            self.popover = popover
            contentView = content
        }
        contentView?.update(context: context)
        if let popover, !popover.isShown, anchor.window != nil {
            popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxX)
        }
    }

    /// Programmatic close (state cleared, cell reuse, teardown) — no callback.
    func dismiss() {
        guard let popover else { return }
        isDismissingProgrammatically = true
        popover.close()
        isDismissingProgrammatically = false
        self.popover = nil
        contentView = nil
    }

    nonisolated func popoverDidClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            let wasProgrammatic = isDismissingProgrammatically
            popover = nil
            contentView = nil
            if !wasProgrammatic {
                onUserClose?()
            }
        }
    }
}

/// The checklist popover content: workspace title + progress header, the
/// ordered item rows (completed sink below unchecked, viewport capped at six
/// rows), an always-armed add field, and an "Open as Pane" footer. AppKit
/// port of `SidebarWorkspaceChecklistPopover`; the arrow-key highlight
/// navigation of the SwiftUI version is not reproduced.
final class SidebarWorkspaceCellChecklistPopoverView: NSView {
    private static let itemFontSize: CGFloat = 13
    private static let checkboxPointSize: CGFloat = 13
    private static let itemRowHeightEstimate: CGFloat = itemFontSize + 6
    private static let visibleRowCount = 6
    private static let rowSpacing: CGFloat = 2

    private let column = SidebarWorkspaceCellStackFactory.vertical(spacing: 0, alignment: .width)
    private let headerRow = SidebarWorkspaceCellStackFactory.horizontal(spacing: 8)
    private let titleLabel = SidebarWorkspaceCellLabel()
    private let headerSpacer = NSView()
    private let countLabel = SidebarWorkspaceCellLabel()

    private let scrollView = NSScrollView()
    private let itemsStack = SidebarWorkspaceCellStackFactory.vertical(spacing: 2, alignment: .width)
    private let itemsPool = SidebarWorkspaceCellRowPool<SidebarWorkspaceCellChecklistItemRowView>()
    private lazy var scrollHeight = scrollView.heightAnchor.constraint(equalToConstant: 0)

    private let addRow = SidebarWorkspaceCellStackFactory.horizontal(spacing: 6)
    private let addIcon = SidebarWorkspaceCellIconView()
    private let addField = FocusGrabbingTextField(string: "")
    private var addCoordinator: SidebarWorkspaceCellPopoverAddFieldDelegate?

    private let footerSeparator = NSBox()
    private let footerButton = SidebarWorkspaceCellButton()

    private var context: SidebarWorkspaceCellContext?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityIdentifier("SidebarWorkspaceChecklistPopover")

        titleLabel.font = SidebarWorkspaceCellFonts.system(13, weight: .semibold)
        titleLabel.textColor = .labelColor
        headerSpacer.translatesAutoresizingMaskIntoConstraints = false
        headerSpacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        countLabel.font = SidebarWorkspaceCellFonts.monospacedDigit(11)
        countLabel.textColor = .secondaryLabelColor
        countLabel.setContentHuggingPriority(.required, for: .horizontal)
        countLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        headerRow.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 6, right: 12)
        headerRow.addArrangedSubview(titleLabel)
        headerRow.addArrangedSubview(headerSpacer)
        headerRow.addArrangedSubview(countLabel)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        let documentView = SidebarWorkspaceCellFlippedView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(itemsStack)
        itemsStack.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
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

        addIcon.setSymbol("plus.circle", pointSize: Self.checkboxPointSize, color: .secondaryLabelColor)
        addField.translatesAutoresizingMaskIntoConstraints = false
        addField.isBordered = false
        addField.drawsBackground = false
        addField.focusRingType = .none
        addField.usesSingleLineMode = true
        addField.cell?.usesSingleLineMode = true
        addField.font = SidebarWorkspaceCellFonts.system(Self.itemFontSize)
        addField.placeholderString = String(
            localized: "sidebar.checklist.addItemPlaceholder",
            defaultValue: "New checklist item"
        )
        addField.setAccessibilityIdentifier("SidebarChecklistPopoverAddItemField")
        addRow.edgeInsets = NSEdgeInsets(top: 2, left: 12, bottom: 8, right: 12)
        addRow.addArrangedSubview(addIcon)
        addRow.addArrangedSubview(addField)

        footerSeparator.boxType = .separator
        footerSeparator.translatesAutoresizingMaskIntoConstraints = false
        footerButton.imagePosition = .imageLeading
        footerButton.alignment = .left
        footerButton.setAccessibilityIdentifier("SidebarChecklistPopoverOpenAsPane")
        footerButton.image = SidebarWorkspaceCellSymbols.image("rectangle.split.2x1", pointSize: 11)
        footerButton.contentTintColor = .secondaryLabelColor
        footerButton.attributedTitle = NSAttributedString(
            string: String(localized: "sidebar.checklist.openAsPane", defaultValue: "Open as Pane"),
            attributes: [
                .font: SidebarWorkspaceCellFonts.system(12),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
        )
        footerButton.onPress = { [weak self] in self?.openAsPane() }
        let footerRow = SidebarWorkspaceCellStackFactory.horizontal(spacing: 0)
        footerRow.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        footerRow.addArrangedSubview(footerButton)

        column.addArrangedSubview(headerRow)
        column.addArrangedSubview(scrollView)
        column.addArrangedSubview(addRow)
        column.addArrangedSubview(footerSeparator)
        column.addArrangedSubview(footerRow)
        addSubview(column)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 320),
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
            column.topAnchor.constraint(equalTo: topAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        let coordinator = SidebarWorkspaceCellPopoverAddFieldDelegate(
            onCommit: { [weak self] text in self?.commitAdd(text) },
            onCancel: { [weak self] in self?.cancelAdd() }
        )
        addField.delegate = coordinator
        addCoordinator = coordinator
    }

    required init?(coder: NSCoder) { nil }

    func update(context: SidebarWorkspaceCellContext) {
        self.context = context
        let workspace = context.workspace

        titleLabel.stringValue = workspace.title
        countLabel.stringValue = "\(workspace.checklistCompletedCount)/\(workspace.checklistTotalCount)"

        let ordered = SidebarWorkspaceChecklistDisplayPolicy.orderedItems(workspace.checklistItems)
        scrollView.isHidden = ordered.isEmpty
        if !ordered.isEmpty {
            let visibleCount = min(ordered.count, Self.visibleRowCount)
            scrollHeight.constant = Self.itemRowHeightEstimate * CGFloat(visibleCount)
                + Self.rowSpacing * CGFloat(visibleCount - 1)
            let appearance = SidebarWorkspaceCellChecklistItemRowView.Appearance(
                checkboxPointSize: Self.checkboxPointSize,
                removePointSize: Self.checkboxPointSize - 2,
                textFont: SidebarWorkspaceCellFonts.system(Self.itemFontSize),
                editFontSize: Self.itemFontSize,
                primaryColor: .labelColor,
                secondaryColor: .secondaryLabelColor
            )
            let actions = context.actions
            let rows = itemsPool.prepare(count: ordered.count, in: itemsStack) {
                SidebarWorkspaceCellChecklistItemRowView()
            }
            for (item, row) in zip(ordered, rows) {
                row.update(
                    item: item,
                    appearance: appearance,
                    isEditing: editingItemId == item.id,
                    setState: { itemId, state in actions?.checklist.setItemState(itemId, state) },
                    remove: { itemId in actions?.checklist.removeItem(itemId) },
                    beginEdit: { [weak self] itemId in
                        self?.editingItemId = itemId
                        if let self, let context = self.context {
                            self.update(context: context)
                        }
                    },
                    finishEdit: { [weak self] itemId, text in
                        self?.editingItemId = nil
                        if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            actions?.checklist.editItem(itemId, text)
                        }
                        if let self, let context = self.context {
                            self.update(context: context)
                        }
                    }
                )
            }
        }
    }

    private var editingItemId: UUID?

    /// Enter commits the trimmed text and re-arms the focused, empty field.
    private func commitAdd(_ text: String) {
        guard let context else { return }
        addField.stringValue = ""
        context.actions?.onConsumeChecklistAddFieldActivation()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        context.actions?.checklist.addItem(text)
        window?.makeFirstResponder(addField)
    }

    /// Escape closes the popover.
    private func cancelAdd() {
        addField.stringValue = ""
        context?.actions?.onChecklistPopoverPresentedChange(false)
    }

    private func openAsPane() {
        guard let context else { return }
        // Close FIRST: popover teardown restores the previous first responder,
        // which would clobber the pane focus openPane() sets up.
        context.actions?.onChecklistPopoverPresentedChange(false)
        context.actions?.checklist.openPane()
    }
}

/// Delegate for the popover's always-armed add field: Return commits (and
/// stays armed for the next item), Escape cancels, and focus loss never
/// commits — a half-typed draft stays in the field.
@MainActor
private final class SidebarWorkspaceCellPopoverAddFieldDelegate: NSObject, NSTextFieldDelegate {
    private let onCommit: (String) -> Void
    private let onCancel: () -> Void

    init(onCommit: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        self.onCommit = onCommit
        self.onCancel = onCancel
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) {
            onCommit(control.stringValue)
            return true
        }
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            onCancel()
            return true
        }
        return false
    }
}

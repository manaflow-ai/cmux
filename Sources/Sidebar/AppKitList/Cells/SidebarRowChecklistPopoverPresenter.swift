import AppKit
import CmuxWorkspaces

@MainActor
final class SidebarRowChecklistPopoverPresenter: NSObject, NSPopoverDelegate {
    private let contentController = SidebarChecklistPopoverViewController()
    private var popover: NSPopover?
    private var closingProgrammatically = false

    var onExternalDismiss: (() -> Void)?
    var isShown: Bool { popover?.isShown == true }

    func present(
        popoverModel: SidebarWorkspaceChecklistPopoverModel,
        rowModel: SidebarWorkspaceRowModel,
        actions: SidebarAppKitRowActions,
        onConsumeAddFieldActivation: @escaping @MainActor () -> Void,
        onClose: @escaping @MainActor () -> Void,
        relativeTo rect: NSRect,
        of view: NSView,
        preferredEdge: NSRectEdge
    ) {
        guard view.window != nil else { return }
        let popover = self.popover ?? makePopover()
        contentController.configure(
            popoverModel: popoverModel,
            rowModel: rowModel,
            actions: actions,
            onConsumeAddFieldActivation: onConsumeAddFieldActivation,
            onClose: onClose
        )
        popover.contentSize = contentController.contentSize
        if popover.isShown { return }
        popover.show(relativeTo: rect, of: view, preferredEdge: preferredEdge)
    }

    func update(
        popoverModel: SidebarWorkspaceChecklistPopoverModel,
        rowModel: SidebarWorkspaceRowModel,
        actions: SidebarAppKitRowActions
    ) {
        guard let popover, popover.isShown else { return }
        contentController.update(
            popoverModel: popoverModel,
            rowModel: rowModel,
            actions: actions
        )
        popover.contentSize = contentController.contentSize
    }

    func close() {
        guard let popover, popover.isShown else { return }
        closingProgrammatically = true
        popover.performClose(nil)
    }

    private func makePopover() -> NSPopover {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = contentController
        popover.delegate = self
        self.popover = popover
        return popover
    }

    func popoverDidShow(_ notification: Notification) {
        guard let window = contentController.view.window else { return }
        window.makeKey()
        window.makeFirstResponder(contentController.view)
        contentController.consumePendingActivation()
    }

    func popoverDidClose(_ notification: Notification) {
        contentController.suspendPresentation()
        let external = !closingProgrammatically
        closingProgrammatically = false
        popover = nil
        if external { onExternalDismiss?() }
        onExternalDismiss = nil
    }
}

@MainActor
private final class SidebarChecklistPopoverViewController: NSViewController {
    private let contentView = SidebarChecklistPopoverView()
    private var onConsumeAddFieldActivation: (@MainActor () -> Void)?

    var contentSize: NSSize { contentView.intrinsicContentSize }

    override func loadView() {
        view = contentView
    }

    func configure(
        popoverModel: SidebarWorkspaceChecklistPopoverModel,
        rowModel: SidebarWorkspaceRowModel,
        actions: SidebarAppKitRowActions,
        onConsumeAddFieldActivation: @escaping @MainActor () -> Void,
        onClose: @escaping @MainActor () -> Void
    ) {
        loadViewIfNeeded()
        self.onConsumeAddFieldActivation = onConsumeAddFieldActivation
        contentView.onClose = onClose
        contentView.update(
            popoverModel: popoverModel,
            rowModel: rowModel,
            actions: actions
        )
    }

    func update(
        popoverModel: SidebarWorkspaceChecklistPopoverModel,
        rowModel: SidebarWorkspaceRowModel,
        actions: SidebarAppKitRowActions
    ) {
        loadViewIfNeeded()
        contentView.update(
            popoverModel: popoverModel,
            rowModel: rowModel,
            actions: actions
        )
    }

    func consumePendingActivation() {
        onConsumeAddFieldActivation?()
    }

    func suspendPresentation() {
        contentView.suspendPresentation()
        onConsumeAddFieldActivation = nil
    }
}

@MainActor
private final class SidebarChecklistPopoverView: NSView {
    private static let width: CGFloat = 320
    private static let inset: CGFloat = 10
    private static let rowSpacing: CGFloat = 2
    private static let maximumVisibleRows = 6
    private static let headerHeight: CGFloat = 34
    private static let footerHeight: CGFloat = 34

    private let titleLabel = NSTextField(labelWithString: "")
    private let progressLabel = NSTextField(labelWithString: "")
    private let closeButton = NSButton()
    private let scrollView = NSScrollView()
    private let itemsDocumentView = SidebarRowChecklistFlippedView()
    private let addRow = SidebarRowChecklistAddRow()
    private let divider = NSBox()
    private let openPaneButton = NSButton()
    private var itemLinesById: [UUID: SidebarRowChecklistItemLine] = [:]
    private var orderedLines: [SidebarRowChecklistItemLine] = []
    private var freeLines: [SidebarRowChecklistItemLine] = []
    private var orderedItems: [WorkspaceChecklistItem] = []
    private var rowModel: SidebarWorkspaceRowModel?
    private var actions: SidebarAppKitRowActions?
    private var measuredItemsHeight: CGFloat = 0
    private var addRowHeight: CGFloat = 0

    var onClose: (@MainActor () -> Void)?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityIdentifier("SidebarWorkspaceChecklistPopover")

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        addSubview(titleLabel)

        progressLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        progressLabel.textColor = .secondaryLabelColor
        progressLabel.alignment = .right
        addSubview(progressLabel)

        closeButton.bezelStyle = .regularSquare
        closeButton.isBordered = false
        closeButton.image = NSImage(
            systemSymbolName: "xmark",
            accessibilityDescription: String(localized: "sidebar.checklist.close", defaultValue: "Close")
        )
        closeButton.target = self
        closeButton.action = #selector(close)
        closeButton.setAccessibilityIdentifier("SidebarChecklistPopoverCloseButton")
        addSubview(closeButton)

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.horizontalScrollElasticity = .none
        scrollView.documentView = itemsDocumentView
        addSubview(scrollView)

        addSubview(addRow)

        divider.boxType = .separator
        addSubview(divider)

        openPaneButton.title = String(
            localized: "sidebar.checklist.openAsPane",
            defaultValue: "Open as Pane"
        )
        openPaneButton.bezelStyle = .regularSquare
        openPaneButton.isBordered = false
        openPaneButton.image = NSImage(systemSymbolName: "rectangle.split.3x1", accessibilityDescription: nil)
        openPaneButton.imagePosition = .imageLeading
        openPaneButton.target = self
        openPaneButton.action = #selector(openPane)
        addSubview(openPaneButton)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        let items = min(measuredItemsHeight, visibleItemsHeightLimit())
        let itemBlock = orderedItems.isEmpty ? 0 : items + 6
        let addBlock = addRow.isHidden ? 0 : addRowHeight + 6
        return NSSize(
            width: Self.width,
            height: Self.inset + Self.headerHeight + itemBlock + addBlock
                + 1 + Self.footerHeight + Self.inset
        )
    }

    func update(
        popoverModel: SidebarWorkspaceChecklistPopoverModel,
        rowModel: SidebarWorkspaceRowModel,
        actions: SidebarAppKitRowActions
    ) {
        self.rowModel = rowModel
        self.actions = actions
        titleLabel.stringValue = popoverModel.workspaceTitle
        progressLabel.stringValue = "\(popoverModel.completedCount)/\(popoverModel.totalCount)"
        orderedItems = SidebarWorkspaceChecklistDisplayPolicy.orderedItems(popoverModel.items)

        var previousById = itemLinesById
        let previousLines = orderedLines
        var reused = Set<ObjectIdentifier>()
        itemLinesById.removeAll(keepingCapacity: true)
        orderedLines = orderedItems.map { item in
            let line = previousById.removeValue(forKey: item.id)
                ?? freeLines.popLast()
                ?? SidebarRowChecklistItemLine()
            if line.superview !== itemsDocumentView { itemsDocumentView.addSubview(line) }
            line.isHidden = false
            reused.insert(ObjectIdentifier(line))
            itemLinesById[item.id] = line
            line.configure(
                item,
                model: rowModel,
                primary: .labelColor,
                secondary: .secondaryLabelColor,
                isEditing: rowModel.editingChecklistItemId == item.id,
                actions: actions
            )
            return line
        }
        for line in previousLines where !reused.contains(ObjectIdentifier(line)) {
            line.resetForReuse()
            line.isHidden = true
            freeLines.append(line)
        }

        addRow.isHidden = !popoverModel.canAddItems
        if popoverModel.canAddItems {
            addRow.configure(
                workspaceId: rowModel.workspaceId,
                model: rowModel,
                secondary: .secondaryLabelColor,
                primary: .labelColor,
                isAdding: true,
                armToken: popoverModel.addFieldActivationToken,
                onBeginAdding: {},
                onCommit: actions.checklistAddItem,
                onCancel: actions.onConsumeChecklistAddFieldActivation
            )
        } else {
            addRow.resetForReuse()
        }

        openPaneButton.isEnabled = true
        layoutItems(width: Self.width - Self.inset * 2)
        addRowHeight = addRow.isHidden
            ? 0
            : addRow.measuredHeight(width: Self.width - Self.inset * 2)
        invalidateIntrinsicContentSize()
        frame.size = intrinsicContentSize
        needsLayout = true
    }

    func suspendPresentation() {
        for line in orderedLines { line.detachPresentation(commitEdits: true)?() }
        addRow.suspendPresentation(commitEdits: true)
        actions = nil
        rowModel = nil
    }

    override func layout() {
        super.layout()
        let width = bounds.width - Self.inset * 2
        var y = Self.inset
        closeButton.frame = NSRect(x: bounds.width - Self.inset - 22, y: y, width: 22, height: 22)
        progressLabel.frame = NSRect(x: closeButton.frame.minX - 50, y: y + 2, width: 45, height: 18)
        titleLabel.frame = NSRect(
            x: Self.inset,
            y: y + 2,
            width: max(20, progressLabel.frame.minX - Self.inset - 6),
            height: 18
        )
        y += Self.headerHeight

        if !orderedItems.isEmpty {
            let height = min(measuredItemsHeight, visibleItemsHeightLimit())
            scrollView.frame = NSRect(x: Self.inset, y: y, width: width, height: height)
            layoutItems(width: scrollView.contentSize.width)
            y += height + 6
        } else {
            scrollView.frame = .zero
        }

        if !addRow.isHidden {
            addRow.frame = NSRect(x: Self.inset, y: y, width: width, height: addRowHeight)
            y += addRowHeight + 6
        }
        divider.frame = NSRect(x: 0, y: y, width: bounds.width, height: 1)
        y += 1
        openPaneButton.frame = NSRect(
            x: Self.inset,
            y: y + 3,
            width: width,
            height: Self.footerHeight - 6
        )
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onClose?()
        } else {
            super.keyDown(with: event)
        }
    }

    private func layoutItems(width: CGFloat) {
        var y: CGFloat = 0
        for (index, line) in orderedLines.enumerated() {
            if index > 0 { y += Self.rowSpacing }
            let height = line.measuredHeight(width: width)
            line.frame = NSRect(x: 0, y: y, width: width, height: height)
            y += height
        }
        measuredItemsHeight = y
        itemsDocumentView.frame = NSRect(x: 0, y: 0, width: width, height: y)
    }

    private func visibleItemsHeightLimit() -> CGFloat {
        guard !orderedLines.isEmpty else { return 0 }
        let count = min(orderedLines.count, Self.maximumVisibleRows)
        return orderedLines.prefix(count).reduce(CGFloat.zero) { partial, line in
            partial + line.frame.height
        } + Self.rowSpacing * CGFloat(max(0, count - 1))
    }

    @objc private func close() {
        onClose?()
    }

    @objc private func openPane() {
        actions?.checklistOpenPane()
        onClose?()
    }
}

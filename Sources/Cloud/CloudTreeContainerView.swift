import AppKit

/// Scroll view + outline host for the Cloud tree.
final class CloudTreeContainerView: NSView {
    private let scrollView = NSScrollView()
    private let outlineView = CloudTreeNSOutlineView()
    private let coordinator: CloudTreeOutlineView.Coordinator
    private let layoutMetrics = CloudTreeLayoutMetrics()

    init(coordinator: CloudTreeOutlineView.Coordinator) {
        self.coordinator = coordinator
        super.init(frame: .zero)
        outlineView.headerView = nil
        outlineView.usesAlternatingRowBackgroundColors = false
        outlineView.style = .plain
        outlineView.selectionHighlightStyle = .regular
        outlineView.rowSizeStyle = .custom
        outlineView.indentationPerLevel = CloudTreeStyleStore.current.indentPerLevel
        outlineView.allowsMultipleSelection = false
        outlineView.autoresizesOutlineColumn = true
        outlineView.floatsGroupRows = false
        outlineView.backgroundColor = .clear
        outlineView.intercellSpacing = NSSize(width: 0, height: 0)
        outlineView.setAccessibilityIdentifier("CloudMachinesTree")

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("node"))
        column.isEditable = false
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle

        outlineView.dataSource = coordinator
        outlineView.delegate = coordinator
        outlineView.target = coordinator
        outlineView.action = #selector(CloudTreeOutlineView.Coordinator.handleSingleClick(_:))
        outlineView.setDraggingSourceOperationMask(.move, forLocal: true)
        outlineView.registerForDraggedTypes([.cloudSidebarRow, DragOverlayRoutingPolicy.bonsplitTabTransferType])
        outlineView.onOpenSelection = { [weak coordinator] in coordinator?.openSelection() }
        outlineView.onMoveSelection = { [weak coordinator] delta in coordinator?.moveSelection(by: delta) }
        outlineView.onMoveMachine = { [weak coordinator] delta in coordinator?.moveSelectedMachine(by: delta) ?? false }
        outlineView.onDisclosure = { [weak coordinator] action in coordinator?.performDisclosure(action) }
        outlineView.onQuickSearch = { [weak coordinator] query in coordinator?.selectQuickSearchMatch(query: query) }
        outlineView.onNativeDragPointerBoundary = { [weak coordinator, weak outlineView] in
            guard let outlineView else { return }
            coordinator?.prepareForNativeDragBoundary(on: outlineView)
        }
        outlineView.onDidBecomeFirstResponder = { [weak self] in
            guard let self, let window = self.window else { return }
            AppDelegate.shared?.noteRightSidebarKeyboardFocusIntent(mode: .machines, in: window)
        }
        coordinator.outlineView = outlineView

        outlineView.contextMenuBuilder = { [weak coordinator] row in
            coordinator?.contextMenu(forRow: row)
        }

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.horizontalScrollElasticity = .none
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.documentView = outlineView
        scrollView.contentInsets = NSEdgeInsets(top: 6, left: 0, bottom: 6, right: 0)
        addSubview(scrollView)
        outlineView.onDocumentContentChanged = { [weak self] in self?.needsLayout = true }
        outlineView.frame = scrollView.contentView.bounds
        outlineView.autoresizingMask = [.width]
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        let viewportWidth = scrollView.contentView.bounds.width
        let documentWidth = layoutMetrics.documentWidth(viewportWidth: viewportWidth)
        let contentHeight = outlineView.numberOfRows > 0
            ? outlineView.rect(ofRow: outlineView.numberOfRows - 1).maxY + scrollView.contentInsets.bottom
            : 0
        let documentHeight = layoutMetrics.documentHeight(
            viewportHeight: scrollView.contentView.bounds.height, contentHeight: contentHeight)
        if abs(outlineView.frame.width - documentWidth) > 0.5 || abs(outlineView.frame.height - documentHeight) > 0.5 {
            outlineView.setFrameSize(NSSize(width: documentWidth, height: documentHeight))
        }
        outlineView.sizeLastColumnToFit()
    }
}

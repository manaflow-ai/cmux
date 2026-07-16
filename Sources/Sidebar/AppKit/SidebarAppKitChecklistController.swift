import AppKit
import CmuxFoundation
import CmuxWorkspaces
import Combine

/// Lazily presents one workspace checklist in native AppKit.
///
/// Collapsed rows do not create this hierarchy or read checklist items. The
/// view starts its single workspace observation only while it is attached as
/// an inline expansion or shown in an `NSPopover`.
@MainActor
final class SidebarAppKitChecklistView: NSView, NSTableViewDataSource, NSTableViewDelegate,
    NSTextFieldDelegate
{
    enum PresentationMode: Equatable {
        case inline
        case popover
    }

    private enum Metrics {
        static let rowHeight: CGFloat = 28
        static let visibleRowLimit = 6
        static let popoverWidth: CGFloat = 320
        static let horizontalInset: CGFloat = 8
        static let verticalInset: CGFloat = 8
        static let addIconSide: CGFloat = 16
        static let auxiliaryRowHeight: CGFloat = 24
    }

    private enum Identifier {
        static let column = NSUserInterfaceItemIdentifier("SidebarAppKitChecklistColumn")
        static let itemCell = NSUserInterfaceItemIdentifier("SidebarAppKitChecklistItemCell")
    }

    private let contentStack = NSStackView()
    private let headerStack = NSStackView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let progressLabel = NSTextField(labelWithString: "")
    private let scrollView = NSScrollView()
    private let tableView = NSTableView()
    private let addStack = NSStackView()
    private let addImageView = NSImageView()
    private let addField = NSTextField(string: "")
    private let separator = NSBox()
    private let openPaneButton = NSButton()
    private var scrollHeightConstraint: NSLayoutConstraint!
    private var addImageWidthConstraint: NSLayoutConstraint!
    private var addImageHeightConstraint: NSLayoutConstraint!
    private var addStackHeightConstraint: NSLayoutConstraint!
    private var openPaneHeightConstraint: NSLayoutConstraint!

    private weak var workspace: Workspace?
    private var mode: PresentationMode = .popover
    private var items: [WorkspaceChecklistItem] = []
    private var checklistObservationTask: Task<Void, Never>?
    private var fontMagnificationObserver: GlobalFontMagnificationChangeObserver?
    private var onPreferredHeightChange: (() -> Void)?
    private var onRequestClose: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setUpHierarchy()
        setUpAccessibility()
        fontMagnificationObserver = GlobalFontMagnificationChangeObserver { [weak self] in
            self?.refreshFontMagnification(notifyPreferredHeightChange: true)
        }
    }

    required init?(coder: NSCoder) {
        nil
    }

    deinit {
        checklistObservationTask?.cancel()
    }

    func configure(
        workspace: Workspace,
        mode: PresentationMode,
        onPreferredHeightChange: @escaping () -> Void,
        onRequestClose: @escaping () -> Void
    ) {
        let identityChanged = self.workspace !== workspace || self.mode != mode
        if identityChanged {
            stopObserving()
        }
        self.onPreferredHeightChange = onPreferredHeightChange
        self.onRequestClose = onRequestClose
        self.mode = mode
        titleLabel.stringValue = workspace.title
        applyMode()
        guard identityChanged else { return }

        self.workspace = workspace
        applyItems(workspace.todoState.checklist, notifyHeightChange: false)

        checklistObservationTask = Task { @MainActor [weak self, weak workspace] in
            guard let workspace else { return }
            for await nextItems in workspace.todoState.$checklist.dropFirst().values {
                guard !Task.isCancelled, let self, self.workspace === workspace else { return }
                self.applyItems(nextItems, notifyHeightChange: true)
            }
        }
    }

    func stopObserving(clearItems: Bool = true) {
        checklistObservationTask?.cancel()
        checklistObservationTask = nil
        workspace = nil
        onPreferredHeightChange = nil
        onRequestClose = nil
        if clearItems {
            items = []
            tableView.reloadData()
            scrollHeightConstraint.constant = 0
            scrollView.isHidden = true
            titleLabel.stringValue = ""
            progressLabel.stringValue = ""
            addField.stringValue = ""
        }
    }

    func focusAddField() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.window?.makeFirstResponder(self.addField)
            self.addField.selectText(nil)
        }
    }

    var preferredContentSize: NSSize {
        frame.size.width = Metrics.popoverWidth
        layoutSubtreeIfNeeded()
        return NSSize(
            width: Metrics.popoverWidth,
            height: ceil(contentStack.fittingSize.height + 2 * Metrics.verticalInset)
        )
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        items.count
    }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard items.indices.contains(row), let workspace else { return nil }
        let item = items[row]
        let cell: SidebarAppKitChecklistItemCellView
        if let reusable = tableView.makeView(
            withIdentifier: Identifier.itemCell,
            owner: nil
        ) as? SidebarAppKitChecklistItemCellView {
            cell = reusable
        } else {
            cell = SidebarAppKitChecklistItemCellView(frame: .zero)
            cell.identifier = Identifier.itemCell
        }

        let isCompleted = item.state == .completed
        let canMoveUp = row > 0 && (items[row - 1].state == .completed) == isCompleted
        let canMoveDown = row + 1 < items.count
            && (items[row + 1].state == .completed) == isCompleted
        cell.configure(
            item: item,
            canMoveUp: canMoveUp,
            canMoveDown: canMoveDown,
            onSetState: { [weak workspace] state in
                guard let workspace else { return }
                WorkspaceTodoActions.setChecklistItemState(
                    id: item.id,
                    state: state,
                    in: workspace
                )
            },
            onEdit: { [weak workspace] text in
                guard let workspace else { return }
                WorkspaceTodoActions.editChecklistItem(
                    id: item.id,
                    text: text,
                    in: workspace
                )
            },
            onRemove: { [weak workspace] in
                guard let workspace else { return }
                WorkspaceTodoActions.removeChecklistItem(id: item.id, from: workspace)
            },
            onMove: { [weak workspace] delta in
                guard let workspace else { return }
                WorkspaceTodoActions.moveChecklistItem(
                    id: item.id,
                    toIndex: row + delta,
                    in: workspace
                )
            }
        )
        return cell
    }

    func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        guard control === addField, !textView.hasMarkedText() else { return false }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            addPendingItem()
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            addField.stringValue = ""
            onRequestClose?()
            return true
        }
        return false
    }

    private func setUpHierarchy() {
        translatesAutoresizingMaskIntoConstraints = false

        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.distribution = .fill
        contentStack.spacing = 4
        addSubview(contentStack)

        setUpHeader()
        setUpTable()
        setUpAddRow()
        setUpFooter()

        for arrangedView in [headerStack, scrollView, addStack, separator, openPaneButton] {
            contentStack.addArrangedSubview(arrangedView)
            arrangedView.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
        }

        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: Metrics.horizontalInset
            ),
            contentStack.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -Metrics.horizontalInset
            ),
            contentStack.topAnchor.constraint(
                equalTo: topAnchor,
                constant: Metrics.verticalInset
            ),
            contentStack.bottomAnchor.constraint(
                equalTo: bottomAnchor,
                constant: -Metrics.verticalInset
            ),
        ])
    }

    private func setUpHeader() {
        headerStack.translatesAutoresizingMaskIntoConstraints = false
        headerStack.orientation = .horizontal
        headerStack.alignment = .firstBaseline
        headerStack.distribution = .fill
        headerStack.spacing = 8

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = GlobalFontMagnification.systemFont(
            ofSize: 13,
            weight: .semibold
        )
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        progressLabel.translatesAutoresizingMaskIntoConstraints = false
        progressLabel.font = GlobalFontMagnification.monospacedDigitSystemFont(
            ofSize: 11,
            weight: .regular
        )
        progressLabel.textColor = .secondaryLabelColor
        progressLabel.alignment = .right
        progressLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        headerStack.addArrangedSubview(titleLabel)
        headerStack.addArrangedSubview(progressLabel)
    }

    private func setUpTable() {
        let column = NSTableColumn(identifier: Identifier.column)
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.gridStyleMask = []
        tableView.intercellSpacing = .zero
        tableView.rowHeight = magnifiedRowHeight
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.selectionHighlightStyle = .none
        tableView.allowsEmptySelection = true
        tableView.focusRingType = .none
        tableView.dataSource = self
        tableView.delegate = self

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.documentView = tableView
        scrollHeightConstraint = scrollView.heightAnchor.constraint(equalToConstant: 0)
        scrollHeightConstraint.isActive = true
    }

    private func setUpAddRow() {
        addStack.translatesAutoresizingMaskIntoConstraints = false
        addStack.orientation = .horizontal
        addStack.alignment = .centerY
        addStack.distribution = .fill
        addStack.spacing = 6

        addImageView.translatesAutoresizingMaskIntoConstraints = false
        addImageView.image = NSImage(systemSymbolName: "plus.circle", accessibilityDescription: nil)
        addImageView.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: GlobalFontMagnification.scaledSize(11),
            weight: .regular
        )
        addImageView.contentTintColor = .secondaryLabelColor
        addImageView.imageScaling = .scaleProportionallyDown
        addImageView.setAccessibilityElement(false)

        addField.translatesAutoresizingMaskIntoConstraints = false
        addField.isBordered = false
        addField.drawsBackground = false
        addField.focusRingType = .none
        addField.usesSingleLineMode = true
        addField.font = GlobalFontMagnification.systemFont(ofSize: 12)
        addField.placeholderString = String(
            localized: "sidebar.checklist.addItemPlaceholder",
            defaultValue: "New checklist item"
        )
        addField.delegate = self
        addField.setAccessibilityIdentifier("SidebarChecklistAppKitAddItemField")

        addStack.addArrangedSubview(addImageView)
        addStack.addArrangedSubview(addField)
        addImageWidthConstraint = addImageView.widthAnchor.constraint(
            equalToConstant: GlobalFontMagnification.scaledSize(Metrics.addIconSide)
        )
        addImageHeightConstraint = addImageView.heightAnchor.constraint(
            equalToConstant: GlobalFontMagnification.scaledSize(Metrics.addIconSide)
        )
        addStackHeightConstraint = addStack.heightAnchor.constraint(
            greaterThanOrEqualToConstant: GlobalFontMagnification.scaledSize(
                Metrics.auxiliaryRowHeight
            )
        )
        NSLayoutConstraint.activate([
            addImageWidthConstraint,
            addImageHeightConstraint,
            addStackHeightConstraint,
        ])
    }

    private func setUpFooter() {
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.boxType = .separator

        openPaneButton.translatesAutoresizingMaskIntoConstraints = false
        openPaneButton.isBordered = false
        openPaneButton.imagePosition = .imageLeading
        openPaneButton.imageHugsTitle = true
        openPaneButton.alignment = .left
        openPaneButton.title = String(
            localized: "sidebar.checklist.openAsPane",
            defaultValue: "Open as Pane"
        )
        openPaneButton.image = NSImage(
            systemSymbolName: "rectangle.split.2x1",
            accessibilityDescription: nil
        )
        openPaneButton.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: GlobalFontMagnification.scaledSize(11),
            weight: .regular
        )
        openPaneButton.font = GlobalFontMagnification.systemFont(ofSize: 12)
        openPaneButton.target = self
        openPaneButton.action = #selector(openAsPane)
        openPaneButton.setAccessibilityIdentifier("SidebarChecklistAppKitOpenAsPane")
        openPaneHeightConstraint = openPaneButton.heightAnchor.constraint(
            greaterThanOrEqualToConstant: GlobalFontMagnification.scaledSize(
                Metrics.auxiliaryRowHeight
            )
        )
        openPaneHeightConstraint.isActive = true
    }

    private func setUpAccessibility() {
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityIdentifier("SidebarWorkspaceChecklistAppKit")
        addField.setAccessibilityLabel(String(
            localized: "sidebar.checklist.addItemPlaceholder",
            defaultValue: "New checklist item"
        ))
        openPaneButton.setAccessibilityLabel(openPaneButton.title)
    }

    private func applyMode() {
        headerStack.isHidden = mode == .inline
    }

    private func applyItems(
        _ nextItems: [WorkspaceChecklistItem],
        notifyHeightChange: Bool
    ) {
        let ordered = SidebarWorkspaceChecklistDisplayPolicy.orderedItems(nextItems)
        guard ordered != items else {
            updateProgressLabel()
            return
        }
        let previousHeight = scrollHeightConstraint.constant
        items = ordered
        tableView.reloadData()
        scrollView.isHidden = items.isEmpty
        scrollView.hasVerticalScroller = items.count > Metrics.visibleRowLimit
        scrollHeightConstraint.constant = magnifiedRowHeight
            * CGFloat(min(items.count, Metrics.visibleRowLimit))
        updateProgressLabel()
        needsLayout = true
        layoutSubtreeIfNeeded()
        if notifyHeightChange, previousHeight != scrollHeightConstraint.constant {
            onPreferredHeightChange?()
        }
    }

    private func updateProgressLabel() {
        let completedCount = items.count { $0.state == .completed }
        progressLabel.stringValue = "\(completedCount)/\(items.count)"
    }

    private var magnifiedRowHeight: CGFloat {
        GlobalFontMagnification.scaledSize(Metrics.rowHeight)
    }

    /// Reapplies magnification-derived presentation to the retained hierarchy.
    ///
    /// The checklist's workspace observation task is deliberately untouched:
    /// live font changes restyle the existing controls and visible row views.
    private func refreshFontMagnification(notifyPreferredHeightChange: Bool) {
        titleLabel.font = GlobalFontMagnification.systemFont(
            ofSize: 13,
            weight: .semibold
        )
        progressLabel.font = GlobalFontMagnification.monospacedDigitSystemFont(
            ofSize: 11,
            weight: .regular
        )
        addField.font = GlobalFontMagnification.systemFont(ofSize: 12)
        openPaneButton.font = GlobalFontMagnification.systemFont(ofSize: 12)

        let symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: GlobalFontMagnification.scaledSize(11),
            weight: .regular
        )
        addImageView.symbolConfiguration = symbolConfiguration
        openPaneButton.symbolConfiguration = symbolConfiguration

        addImageWidthConstraint.constant = GlobalFontMagnification.scaledSize(
            Metrics.addIconSide
        )
        addImageHeightConstraint.constant = GlobalFontMagnification.scaledSize(
            Metrics.addIconSide
        )
        addStackHeightConstraint.constant = GlobalFontMagnification.scaledSize(
            Metrics.auxiliaryRowHeight
        )
        openPaneHeightConstraint.constant = GlobalFontMagnification.scaledSize(
            Metrics.auxiliaryRowHeight
        )

        let rowHeight = magnifiedRowHeight
        tableView.rowHeight = rowHeight
        scrollHeightConstraint.constant = rowHeight
            * CGFloat(min(items.count, Metrics.visibleRowLimit))
        refreshVisibleItemCells()

        titleLabel.invalidateIntrinsicContentSize()
        progressLabel.invalidateIntrinsicContentSize()
        addField.invalidateIntrinsicContentSize()
        openPaneButton.invalidateIntrinsicContentSize()
        contentStack.needsLayout = true
        needsLayout = true
        layoutSubtreeIfNeeded()

        if notifyPreferredHeightChange {
            onPreferredHeightChange?()
        }
    }

    /// At most the six-row viewport is visited, regardless of checklist size.
    private func refreshVisibleItemCells() {
        let visibleRows = tableView.rows(in: tableView.visibleRect)
        guard visibleRows.location != NSNotFound else { return }
        let upperBound = min(tableView.numberOfRows, NSMaxRange(visibleRows))
        guard visibleRows.location < upperBound else { return }
        for row in visibleRows.location..<upperBound {
            let cell = tableView.view(
                atColumn: 0,
                row: row,
                makeIfNecessary: false
            ) as? SidebarAppKitChecklistItemCellView
            cell?.refreshFontMagnification()
        }
    }

    private func addPendingItem() {
        guard let workspace else { return }
        let text = addField.stringValue
        addField.stringValue = ""
        if !WorkspaceTodoActions.addChecklistItem(text: text, to: workspace) {
            NSSound.beep()
        }
        focusAddField()
    }

    @objc private func openAsPane() {
        guard let workspace else { return }
        if mode == .popover {
            onRequestClose?()
        }
        if WorkspaceTodoActions.openTodoPane(for: workspace) == nil {
            NSSound.beep()
        }
    }
}

/// Native, reusable row for one checklist item.
@MainActor
private final class SidebarAppKitChecklistItemCellView: NSTableCellView, NSTextFieldDelegate {
    private enum Metrics {
        static let controlSide: CGFloat = 20
    }

    private let stack = NSStackView()
    private let stateButton = NSButton()
    private let itemField = NSTextField(string: "")
    private let moveUpButton = NSButton()
    private let moveDownButton = NSButton()
    private let removeButton = NSButton()

    private var item: WorkspaceChecklistItem?
    private var baselineText = ""
    private var onSetState: ((WorkspaceChecklistItem.State) -> Void)?
    private var onEdit: ((String) -> Void)?
    private var onRemove: (() -> Void)?
    private var onMove: ((Int) -> Void)?
    private var canMoveUp = false
    private var canMoveDown = false
    private var imageButtonSizeConstraints: [(
        button: NSButton,
        width: NSLayoutConstraint,
        height: NSLayoutConstraint
    )] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setUpHierarchy()
    }

    required init?(coder: NSCoder) {
        nil
    }

    func configure(
        item: WorkspaceChecklistItem,
        canMoveUp: Bool,
        canMoveDown: Bool,
        onSetState: @escaping (WorkspaceChecklistItem.State) -> Void,
        onEdit: @escaping (String) -> Void,
        onRemove: @escaping () -> Void,
        onMove: @escaping (Int) -> Void
    ) {
        self.item = item
        baselineText = item.text
        self.onSetState = onSetState
        self.onEdit = onEdit
        self.onRemove = onRemove
        self.onMove = onMove
        self.canMoveUp = canMoveUp
        self.canMoveDown = canMoveDown

        itemField.stringValue = item.text
        itemField.textColor = item.state == .completed ? .secondaryLabelColor : .labelColor
        let attributes: [NSAttributedString.Key: Any] = item.state == .completed
            ? [.strikethroughStyle: NSUnderlineStyle.single.rawValue]
            : [:]
        itemField.attributedStringValue = NSAttributedString(string: item.text, attributes: attributes)

        let symbolName: String
        let stateHelp: String
        switch item.state {
        case .pending:
            symbolName = "square"
            stateHelp = String(
                localized: "sidebar.checklist.checkTooltip",
                defaultValue: "Mark as completed"
            )
        case .inProgress:
            symbolName = "minus.square"
            stateHelp = String(
                localized: "sidebar.checklist.checkTooltip",
                defaultValue: "Mark as completed"
            )
        case .completed:
            symbolName = "checkmark.square.fill"
            stateHelp = String(
                localized: "sidebar.checklist.uncheckTooltip",
                defaultValue: "Mark as pending"
            )
        }
        stateButton.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        stateButton.toolTip = stateHelp
        stateButton.setAccessibilityLabel(stateHelp)
        moveUpButton.isEnabled = canMoveUp
        moveDownButton.isEnabled = canMoveDown
        refreshFontMagnification()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let item else { return nil }
        let menu = NSMenu()
        menu.autoenablesItems = false
        addMenuItem(
            to: menu,
            title: String(
                localized: "sidebar.checklist.uncheckTooltip",
                defaultValue: "Mark as pending"
            ),
            action: #selector(markPending),
            state: item.state == .pending ? .on : .off
        )
        addMenuItem(
            to: menu,
            title: String(
                localized: "sidebar.checklist.markInProgress",
                defaultValue: "Mark In Progress"
            ),
            action: #selector(markInProgress),
            state: item.state == .inProgress ? .on : .off
        )
        addMenuItem(
            to: menu,
            title: String(
                localized: "sidebar.checklist.checkTooltip",
                defaultValue: "Mark as completed"
            ),
            action: #selector(markCompleted),
            state: item.state == .completed ? .on : .off
        )
        menu.addItem(.separator())
        addMenuItem(
            to: menu,
            title: String(localized: "sidebar.checklist.editItem", defaultValue: "Edit"),
            action: #selector(beginEditing)
        )
        addMenuItem(
            to: menu,
            title: String(localized: "contextMenu.moveUp", defaultValue: "Move Up"),
            action: #selector(moveUp),
            enabled: canMoveUp
        )
        addMenuItem(
            to: menu,
            title: String(localized: "contextMenu.moveDown", defaultValue: "Move Down"),
            action: #selector(moveDown),
            enabled: canMoveDown
        )
        menu.addItem(.separator())
        addMenuItem(
            to: menu,
            title: String(
                localized: "sidebar.checklist.removeItem",
                defaultValue: "Remove"
            ),
            action: #selector(removeItem)
        )
        return menu
    }

    func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        guard control === itemField, !textView.hasMarkedText() else { return false }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            commitEdit()
            window?.makeFirstResponder(enclosingScrollView?.documentView)
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            itemField.stringValue = baselineText
            window?.makeFirstResponder(enclosingScrollView?.documentView)
            return true
        }
        return false
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard notification.object as? NSTextField === itemField else { return }
        commitEdit()
    }

    private func setUpHierarchy() {
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.distribution = .fill
        stack.spacing = 4
        addSubview(stack)

        configureImageButton(stateButton, symbolName: "square", action: #selector(cycleState))

        itemField.translatesAutoresizingMaskIntoConstraints = false
        itemField.isBordered = false
        itemField.drawsBackground = false
        itemField.focusRingType = .none
        itemField.usesSingleLineMode = true
        itemField.lineBreakMode = .byTruncatingTail
        itemField.font = GlobalFontMagnification.systemFont(ofSize: 12)
        itemField.placeholderString = String(
            localized: "sidebar.checklist.editItemPlaceholder",
            defaultValue: "Item text"
        )
        itemField.delegate = self
        itemField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        itemField.setAccessibilityIdentifier("SidebarChecklistAppKitEditItemField")

        configureImageButton(moveUpButton, symbolName: "chevron.up", action: #selector(moveUp))
        moveUpButton.toolTip = String(localized: "contextMenu.moveUp", defaultValue: "Move Up")
        moveUpButton.setAccessibilityLabel(moveUpButton.toolTip)

        configureImageButton(moveDownButton, symbolName: "chevron.down", action: #selector(moveDown))
        moveDownButton.toolTip = String(localized: "contextMenu.moveDown", defaultValue: "Move Down")
        moveDownButton.setAccessibilityLabel(moveDownButton.toolTip)

        configureImageButton(removeButton, symbolName: "xmark.circle.fill", action: #selector(removeItem))
        removeButton.toolTip = String(
            localized: "sidebar.checklist.removeItemTooltip",
            defaultValue: "Remove item"
        )
        removeButton.setAccessibilityLabel(removeButton.toolTip)

        [stateButton, itemField, moveUpButton, moveDownButton, removeButton]
            .forEach(stack.addArrangedSubview)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
        ])
    }

    private func configureImageButton(
        _ button: NSButton,
        symbolName: String,
        action: Selector
    ) {
        button.translatesAutoresizingMaskIntoConstraints = false
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        button.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: GlobalFontMagnification.scaledSize(11),
            weight: .regular
        )
        button.target = self
        button.action = action
        let widthConstraint = button.widthAnchor.constraint(
            equalToConstant: GlobalFontMagnification.scaledSize(
                Metrics.controlSide
            )
        )
        let heightConstraint = button.heightAnchor.constraint(
            equalToConstant: GlobalFontMagnification.scaledSize(
                Metrics.controlSide
            )
        )
        NSLayoutConstraint.activate([widthConstraint, heightConstraint])
        imageButtonSizeConstraints.append((
            button: button,
            width: widthConstraint,
            height: heightConstraint
        ))
    }

    func refreshFontMagnification() {
        itemField.font = GlobalFontMagnification.systemFont(ofSize: 12)
        let symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: GlobalFontMagnification.scaledSize(11),
            weight: .regular
        )
        let controlSide = GlobalFontMagnification.scaledSize(
            Metrics.controlSide
        )
        for constraints in imageButtonSizeConstraints {
            constraints.button.symbolConfiguration = symbolConfiguration
            constraints.width.constant = controlSide
            constraints.height.constant = controlSide
            constraints.button.invalidateIntrinsicContentSize()
        }
        itemField.invalidateIntrinsicContentSize()
        stack.needsLayout = true
        needsLayout = true
    }

    private func addMenuItem(
        to menu: NSMenu,
        title: String,
        action: Selector,
        state: NSControl.StateValue = .off,
        enabled: Bool = true
    ) {
        let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: "")
        menuItem.target = self
        menuItem.state = state
        menuItem.isEnabled = enabled
        menu.addItem(menuItem)
    }

    private func commitEdit() {
        let text = itemField.stringValue
        guard text != baselineText else { return }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            itemField.stringValue = baselineText
            return
        }
        baselineText = text
        onEdit?(text)
    }

    @objc private func cycleState() {
        guard let item else { return }
        let next: WorkspaceChecklistItem.State = item.state == .completed
            ? .pending
            : .completed
        onSetState?(next)
    }

    @objc private func markPending() {
        onSetState?(.pending)
    }

    @objc private func markInProgress() {
        onSetState?(.inProgress)
    }

    @objc private func markCompleted() {
        onSetState?(.completed)
    }

    @objc private func beginEditing() {
        window?.makeFirstResponder(itemField)
        itemField.selectText(nil)
    }

    @objc private func moveUp() {
        onMove?(-1)
    }

    @objc private func moveDown() {
        onMove?(1)
    }

    @objc private func removeItem() {
        onRemove?()
    }
}

/// Owns the one native checklist popover used by the sidebar.
@MainActor
final class SidebarAppKitChecklistPopoverController: NSObject, NSPopoverDelegate {
    private var popover: NSPopover?
    private var checklistView: SidebarAppKitChecklistView?
    private weak var presentedWorkspace: Workspace?

    @discardableResult
    func toggle(
        workspace: Workspace,
        relativeTo anchorView: NSView,
        focusAddField: Bool
    ) -> Bool {
        if let popover, popover.isShown, presentedWorkspace === workspace {
            if focusAddField {
                checklistView?.focusAddField()
            } else {
                close()
            }
            return true
        }
        return present(
            workspace: workspace,
            relativeTo: anchorView,
            focusAddField: focusAddField
        )
    }

    @discardableResult
    func present(
        workspace: Workspace,
        relativeTo anchorView: NSView,
        focusAddField: Bool
    ) -> Bool {
        guard anchorView.window != nil else { return false }
        close()

        let checklistView = SidebarAppKitChecklistView(frame: NSRect(
            x: 0,
            y: 0,
            width: 320,
            height: 1
        ))
        let viewController = NSViewController()
        viewController.view = checklistView

        let popover = NSPopover()
        popover.animates = false
        popover.behavior = .transient
        popover.delegate = self
        popover.contentViewController = viewController

        self.popover = popover
        self.checklistView = checklistView
        presentedWorkspace = workspace
        checklistView.configure(
            workspace: workspace,
            mode: .popover,
            onPreferredHeightChange: { [weak self] in
                self?.refreshPopoverSize()
            },
            onRequestClose: { [weak self] in
                self?.close()
            }
        )
        refreshPopoverSize()
        popover.show(relativeTo: anchorView.bounds, of: anchorView, preferredEdge: .maxX)
        if focusAddField {
            checklistView.focusAddField()
        }
        return true
    }

    func close() {
        let closingPopover = popover
        closingPopover?.delegate = nil
        if closingPopover?.isShown == true {
            closingPopover?.performClose(nil)
        }
        tearDown()
    }

    func popoverDidClose(_ notification: Notification) {
        tearDown()
    }

    private func refreshPopoverSize() {
        guard let checklistView else { return }
        let size = checklistView.preferredContentSize
        popover?.contentSize = size
        popover?.contentViewController?.preferredContentSize = size
    }

    private func tearDown() {
        checklistView?.stopObserving()
        popover?.delegate = nil
        popover?.contentViewController = nil
        popover = nil
        checklistView = nil
        presentedWorkspace = nil
    }
}

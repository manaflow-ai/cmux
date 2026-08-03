import AppKit
import CmuxWorkspaces
import Combine

enum WorkspaceTodoPaneHeaderTitle {
    nonisolated static func title(paneTitle: String) -> String {
        paneTitle
    }
}

enum WorkspaceTodoPaneHeaderStatusLabel {
    nonisolated static func displayName(
        effective: WorkspaceTaskStatus?,
        hasOverride: Bool
    ) -> String? {
        guard let effective else { return nil }
        if effective == .todo && !hasOverride { return nil }
        return effective.displayName
    }
}

enum WorkspaceTodoPaneItemRowClickPolicy {
    enum Action: Equatable {
        case select
        case beginEdit
        case focusEditor
    }

    nonisolated static func action(isEditing: Bool, isHighlighted: Bool) -> Action {
        if isEditing { return .focusEditor }
        if isHighlighted { return .beginEdit }
        return .select
    }
}

enum WorkspaceTodoPaneKeyboardNavigationPolicy {
    nonisolated static func shouldMoveHighlight(isEditing: Bool, hasItems: Bool) -> Bool {
        !isEditing && hasItems
    }
}

@MainActor
final class WorkspaceTodoPanelNativeViewController: NSViewController,
    PanelContentControllerUpdating,
    NSTableViewDataSource,
    NSTableViewDelegate
{
    fileprivate static let itemFont = NSFont.systemFont(ofSize: 13)
    private static let itemPasteboardType = NSPasteboard.PasteboardType(
        "com.cmux.workspace-todo-item"
    )

    private var configuration: PanelContentConfiguration
    private weak var panel: WorkspaceTodoPanel?
    private weak var workspace: Workspace?
    private var orderedItems: [WorkspaceChecklistItem] = []
    private var panelCancellable: AnyCancellable?
    private var workspaceCancellable: AnyCancellable?
    private var todoCancellable: AnyCancellable?
    private var refreshTask: Task<Void, Never>?
    private var highlightedItemID: UUID?
    private var editingItemID: UUID?
    private var editingText = ""
    private var lastAddFieldArmToken = -1
    private var wasFocused = false
    private var lastFocusFlashToken = 0

    private let rootView = WorkspaceTodoPanelRootView()
    private let headerView = WorkspaceTodoPaneHeaderNativeView()
    private let topDivider = NSBox()
    private let scrollView = NSScrollView()
    private let tableView = WorkspaceTodoTableView()
    private let emptyLabel = NSTextField(labelWithString: String(
        localized: "workspaceTodoPane.emptyChecklist",
        defaultValue: "No checklist items yet."
    ))
    private let bottomDivider = NSBox()
    private let addFieldView = WorkspaceTodoAddFieldNativeView()
    private let unavailableLabel = NSTextField(wrappingLabelWithString: String(
        localized: "workspaceTodoPane.workspaceUnavailable",
        defaultValue: "This workspace is no longer available."
    ))
    private let flashRing = WorkspaceAttentionFlashRingNativeView(frame: .zero)
    private var addFieldHeightConstraint: NSLayoutConstraint?
    private var bottomDividerHeightConstraint: NSLayoutConstraint?

    init(configuration: PanelContentConfiguration) {
        self.configuration = configuration
        super.init(nibName: nil, bundle: nil)
        update(configuration: configuration)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        rootView.wantsLayer = true
        rootView.setAccessibilityIdentifier("WorkspaceTodoPane")
        rootView.onPointerDown = { [weak self] in
            self?.configuration.onRequestPanelFocus()
        }

        topDivider.boxType = .separator
        bottomDivider.boxType = .separator
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.documentView = tableView
        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .regular
        tableView.rowHeight = 28
        tableView.intercellSpacing = .zero
        tableView.delegate = self
        tableView.dataSource = self
        tableView.addTableColumn(NSTableColumn(identifier: .init("todo")))
        tableView.registerForDraggedTypes([Self.itemPasteboardType])
        tableView.setDraggingSourceOperationMask(.move, forLocal: true)
        tableView.onRowClick = { [weak self] row, wasSelected in
            self?.handleRowClick(row: row, wasSelected: wasSelected)
        }
        tableView.onToggleSelectedItem = { [weak self] in
            self?.toggleHighlightedItem()
        }

        emptyLabel.font = Self.itemFont
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        unavailableLabel.font = .systemFont(ofSize: 13)
        unavailableLabel.textColor = .secondaryLabelColor
        unavailableLabel.alignment = .center
        unavailableLabel.maximumNumberOfLines = 0

        [
            headerView,
            topDivider,
            scrollView,
            emptyLabel,
            unavailableLabel,
            bottomDivider,
            addFieldView,
            flashRing,
        ].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            rootView.addSubview($0)
        }
        let addHeight = addFieldView.heightAnchor.constraint(equalToConstant: 36)
        let bottomDividerHeight = bottomDivider.heightAnchor.constraint(equalToConstant: 1)
        addFieldHeightConstraint = addHeight
        bottomDividerHeightConstraint = bottomDividerHeight
        NSLayoutConstraint.activate([
            headerView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            headerView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            headerView.topAnchor.constraint(equalTo: rootView.topAnchor),
            headerView.heightAnchor.constraint(equalToConstant: 44),
            topDivider.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            topDivider.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            topDivider.topAnchor.constraint(equalTo: headerView.bottomAnchor),
            topDivider.heightAnchor.constraint(equalToConstant: 1),
            scrollView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topDivider.bottomAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomDivider.topAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            unavailableLabel.centerXAnchor.constraint(equalTo: rootView.centerXAnchor),
            unavailableLabel.centerYAnchor.constraint(equalTo: rootView.centerYAnchor),
            unavailableLabel.leadingAnchor.constraint(greaterThanOrEqualTo: rootView.leadingAnchor, constant: 24),
            unavailableLabel.trailingAnchor.constraint(lessThanOrEqualTo: rootView.trailingAnchor, constant: -24),
            bottomDivider.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            bottomDivider.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            bottomDivider.bottomAnchor.constraint(equalTo: addFieldView.topAnchor),
            bottomDividerHeight,
            addFieldView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: 14),
            addFieldView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -14),
            addFieldView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),
            addHeight,
            flashRing.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            flashRing.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            flashRing.topAnchor.constraint(equalTo: rootView.topAnchor),
            flashRing.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),
        ])
        addFieldView.onCommit = { [weak self] text in self?.addItem(text) }
        addFieldView.onCancel = { [weak self] in self?.cancelAdding() }
        addFieldView.onHeightChange = { [weak self] height in
            self?.addFieldHeightConstraint?.constant = height
        }
        view = rootView
    }

    func update(configuration: PanelContentConfiguration) {
        self.configuration = configuration
        loadViewIfNeeded()
        guard let panel = configuration.panel as? WorkspaceTodoPanel else { return }
        observe(panel: panel, workspace: panel.workspace)
        refresh()
    }

    func teardownPanelContent() {
        panelCancellable = nil
        workspaceCancellable = nil
        todoCancellable = nil
        refreshTask?.cancel()
        refreshTask = nil
        headerView.teardown()
        addFieldView.teardown()
        rootView.onPointerDown = nil
        panel = nil
        workspace = nil
    }

    isolated deinit {
        refreshTask?.cancel()
    }

    private func observe(panel: WorkspaceTodoPanel, workspace: Workspace?) {
        if self.panel !== panel {
            panelCancellable = panel.objectWillChange.sink { [weak self] in
                self?.scheduleRefreshAfterChange()
            }
            self.panel = panel
            lastFocusFlashToken = panel.focusFlashToken
        }
        guard self.workspace !== workspace else { return }
        workspaceCancellable = workspace?.objectWillChange.sink { [weak self] in
            self?.scheduleRefreshAfterChange()
        }
        todoCancellable = workspace?.todoState.objectWillChange.sink { [weak self] in
            self?.scheduleRefreshAfterChange()
        }
        self.workspace = workspace
    }

    private func scheduleRefreshAfterChange() {
        Task { @MainActor [weak self] in
            await Task.yield()
            self?.scheduleRefresh()
        }
    }

    private func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }

    private func refresh() {
        rootView.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        guard let panel, let workspace else {
            headerView.isHidden = true
            topDivider.isHidden = true
            scrollView.isHidden = true
            emptyLabel.isHidden = true
            bottomDivider.isHidden = true
            addFieldView.isHidden = true
            unavailableLabel.isHidden = false
            return
        }

        headerView.isHidden = false
        topDivider.isHidden = false
        scrollView.isHidden = false
        unavailableLabel.isHidden = true
        let todoState = workspace.todoState
        let inferred = workspace.inferredTaskStatus
        let resolution = WorkspaceTaskStatusOverride.effectiveStatus(
            override: todoState.statusOverride,
            inferred: inferred
        )
        let controlsEnabled = WorkspaceTodoFeature.isEnabled
        let hasOverride = controlsEnabled
            && todoState.statusOverride != nil
            && !resolution.shouldClearOverride
        headerView.update(
            title: WorkspaceTodoPaneHeaderTitle.title(paneTitle: panel.displayTitle),
            effectiveStatus: controlsEnabled ? resolution.effective : nil,
            inferredStatus: inferred,
            hasOverride: hasOverride,
            statusLabel: WorkspaceTodoPaneHeaderStatusLabel.displayName(
                effective: controlsEnabled ? resolution.effective : nil,
                hasOverride: hasOverride
            ),
            progress: todoState.checklist.checklistProgressSummary,
            workspace: workspace
        )

        orderedItems = SidebarWorkspaceChecklistDisplayPolicy.orderedItems(todoState.checklist)
        if let editingItemID, !orderedItems.contains(where: { $0.id == editingItemID }) {
            self.editingItemID = nil
            editingText = ""
        }
        tableView.reloadData()
        emptyLabel.isHidden = !orderedItems.isEmpty
        if let highlightedItemID,
           let row = orderedItems.firstIndex(where: { $0.id == highlightedItemID }) {
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        } else {
            highlightedItemID = nil
            tableView.deselectAll(nil)
        }

        bottomDivider.isHidden = !controlsEnabled
        addFieldView.isHidden = !controlsEnabled
        bottomDividerHeightConstraint?.constant = controlsEnabled ? 1 : 0
        addFieldHeightConstraint?.constant = controlsEnabled ? addFieldView.preferredHeight : 0
        if controlsEnabled {
            addFieldView.updateColors(primary: .labelColor, secondary: .secondaryLabelColor)
        }

        let shouldArmAddField = controlsEnabled
            && configuration.isFocused
            && editingItemID == nil
            && (!wasFocused || lastAddFieldArmToken != panel.addFieldArmToken)
        wasFocused = configuration.isFocused
        lastAddFieldArmToken = panel.addFieldArmToken
        if shouldArmAddField {
            addFieldView.focus()
        }
        if lastFocusFlashToken != panel.focusFlashToken {
            lastFocusFlashToken = panel.focusFlashToken
            flashRing.triggerFlash(reason: .navigation)
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        orderedItems.count
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard orderedItems.indices.contains(row) else { return 28 }
        let item = orderedItems[row]
        let text = editingItemID == item.id ? editingText : item.text
        let availableWidth = max(80, tableView.bounds.width - 80)
        let bounds = (text as NSString).boundingRect(
            with: NSSize(width: availableWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: Self.itemFont]
        )
        let lineHeight = ceil(Self.itemFont.ascender - Self.itemFont.descender + Self.itemFont.leading)
        return max(28, min(ceil(bounds.height), lineHeight * 8) + 8)
    }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard orderedItems.indices.contains(row), let workspace else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("WorkspaceTodoPaneItemRow")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self)
            as? WorkspaceTodoPaneItemCellView
            ?? WorkspaceTodoPaneItemCellView()
        cell.identifier = identifier
        let item = orderedItems[row]
        cell.configure(
            item: item,
            isEditing: editingItemID == item.id,
            editingText: editingItemID == item.id ? editingText : item.text,
            onToggle: { [weak workspace] in
                guard let workspace else { return }
                WorkspaceTodoActions.setChecklistItemState(
                    id: item.id,
                    state: item.state == .completed ? .pending : .completed,
                    in: workspace
                )
            },
            onEditChange: { [weak self] text in
                guard let self, self.editingItemID == item.id else { return }
                self.editingText = text
                if let row = self.orderedItems.firstIndex(where: { $0.id == item.id }) {
                    self.tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integer: row))
                }
            },
            onCommitEdit: { [weak self] text in self?.commitEdit(itemID: item.id, text: text) },
            onCancelEdit: { [weak self] in self?.cancelEdit(itemID: item.id) },
            onBeginEdit: { [weak self] in self?.beginEdit(item) },
            onMarkInProgress: { [weak workspace] in
                guard let workspace else { return }
                WorkspaceTodoActions.setChecklistItemState(id: item.id, state: .inProgress, in: workspace)
            },
            onRemove: { [weak workspace] in
                guard let workspace else { return }
                WorkspaceTodoActions.removeChecklistItem(id: item.id, from: workspace)
            },
            onAddAttachments: { [weak workspace] itemID in
                guard let workspace else { return }
                WorkspaceTodoActions.addImageAttachments(to: itemID, in: workspace)
            },
            onRemoveAttachment: { [weak workspace] itemID, attachmentID in
                guard let workspace else { return }
                WorkspaceTodoActions.removeImageAttachment(
                    itemId: itemID,
                    attachmentId: attachmentID,
                    from: workspace
                )
            },
            onOpenAttachments: { [weak workspace] _, attachmentID in
                guard let workspace else { return }
                WorkspaceTodoActions.openImageAttachments(
                    item.attachments,
                    selectedAttachmentId: attachmentID
                )
            }
        )
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        guard orderedItems.indices.contains(row) else {
            highlightedItemID = nil
            return
        }
        highlightedItemID = orderedItems[row].id
    }

    func tableView(
        _ tableView: NSTableView,
        pasteboardWriterForRow row: Int
    ) -> (any NSPasteboardWriting)? {
        guard orderedItems.indices.contains(row) else { return nil }
        let item = NSPasteboardItem()
        item.setString(orderedItems[row].id.uuidString, forType: Self.itemPasteboardType)
        return item
    }

    func tableView(
        _ tableView: NSTableView,
        validateDrop info: any NSDraggingInfo,
        proposedRow row: Int,
        proposedDropOperation dropOperation: NSTableView.DropOperation
    ) -> NSDragOperation {
        guard dropOperation == .above,
              info.draggingPasteboard.string(forType: Self.itemPasteboardType) != nil else { return [] }
        return .move
    }

    func tableView(
        _ tableView: NSTableView,
        acceptDrop info: any NSDraggingInfo,
        row: Int,
        dropOperation: NSTableView.DropOperation
    ) -> Bool {
        guard let workspace,
              let rawID = info.draggingPasteboard.string(forType: Self.itemPasteboardType),
              let itemID = UUID(uuidString: rawID) else { return false }
        WorkspaceTodoActions.moveChecklistItem(id: itemID, toIndex: row, in: workspace)
        return true
    }

    private func handleRowClick(row: Int, wasSelected: Bool) {
        guard orderedItems.indices.contains(row) else { return }
        let item = orderedItems[row]
        switch WorkspaceTodoPaneItemRowClickPolicy.action(
            isEditing: editingItemID == item.id,
            isHighlighted: wasSelected
        ) {
        case .select:
            highlightedItemID = item.id
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        case .beginEdit:
            beginEdit(item)
        case .focusEditor:
            (tableView.view(atColumn: 0, row: row, makeIfNecessary: false)
                as? WorkspaceTodoPaneItemCellView)?.focusEditor()
        }
    }

    private func toggleHighlightedItem() {
        guard editingItemID == nil,
              let workspace,
              let highlightedItemID,
              let item = orderedItems.first(where: { $0.id == highlightedItemID }) else { return }
        WorkspaceTodoActions.setChecklistItemState(
            id: item.id,
            state: item.state == .completed ? .pending : .completed,
            in: workspace
        )
    }

    private func beginEdit(_ item: WorkspaceChecklistItem) {
        editingItemID = item.id
        editingText = item.text
        tableView.reloadData(
            forRowIndexes: IndexSet(integersIn: 0..<orderedItems.count),
            columnIndexes: IndexSet(integer: 0)
        )
    }

    private func commitEdit(itemID: UUID, text: String) {
        guard editingItemID == itemID, let workspace else { return }
        editingItemID = nil
        editingText = ""
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            WorkspaceTodoActions.editChecklistItem(id: itemID, text: text, in: workspace)
        }
        scheduleRefresh()
    }

    private func cancelEdit(itemID: UUID) {
        guard editingItemID == itemID else { return }
        editingItemID = nil
        editingText = ""
        scheduleRefresh()
    }

    private func addItem(_ text: String) {
        guard WorkspaceTodoFeature.isEnabled, let workspace else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        WorkspaceTodoActions.addChecklistItem(text: text, to: workspace)
        addFieldView.clearAndRefocus()
    }

    private func cancelAdding() {
        addFieldView.clear()
        _ = view.window?.makeFirstResponder(tableView)
    }
}

@MainActor
private final class WorkspaceTodoPaneHeaderNativeView: NSView {
    private let statusButton = SidebarRowTaskStatusGlyphButton()
    private let titleLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let progressLabel = NSTextField(labelWithString: "")
    private let popoverPresenter = SidebarRowStatusPopoverPresenter()
    private weak var workspace: Workspace?
    private var inferredStatus: WorkspaceTaskStatus = .todo
    private var effectiveStatus: WorkspaceTaskStatus?
    private var hasOverride = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        [statusButton, titleLabel, statusLabel, progressLabel].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }
        let statusSize = SidebarRowTaskStatusGlyphButton.occupiedSize(fontScale: 13.0 / 9.0)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        progressLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        progressLabel.textColor = .secondaryLabelColor
        NSLayoutConstraint.activate([
            statusButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            statusButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            statusButton.widthAnchor.constraint(equalToConstant: statusSize.width),
            statusButton.heightAnchor.constraint(equalToConstant: statusSize.height),
            titleLabel.leadingAnchor.constraint(equalTo: statusButton.trailingAnchor, constant: 8),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            statusLabel.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 8),
            statusLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            progressLabel.leadingAnchor.constraint(greaterThanOrEqualTo: statusLabel.trailingAnchor, constant: 8),
            progressLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            progressLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        statusButton.onClick = { [weak self] in self?.toggleStatusPopover() }
        statusButton.setAccessibilityIdentifier("WorkspaceTodoPaneStatusGlyph")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(
        title: String,
        effectiveStatus: WorkspaceTaskStatus?,
        inferredStatus: WorkspaceTaskStatus,
        hasOverride: Bool,
        statusLabel: String?,
        progress: WorkspaceChecklistProgressSummary,
        workspace: Workspace
    ) {
        self.workspace = workspace
        self.inferredStatus = inferredStatus
        self.effectiveStatus = effectiveStatus
        self.hasOverride = hasOverride
        titleLabel.stringValue = title
        self.statusLabel.stringValue = statusLabel ?? ""
        self.statusLabel.isHidden = statusLabel == nil
        progressLabel.stringValue = progress.totalCount > 0
            ? "\(progress.completedCount)/\(progress.totalCount)"
            : ""
        progressLabel.isHidden = progress.totalCount == 0
        statusButton.isHidden = effectiveStatus == nil
        if let effectiveStatus {
            statusButton.configure(
                model: .init(
                    status: effectiveStatus,
                    hasOverride: hasOverride,
                    usesMonochrome: false,
                    fontScale: 13.0 / 9.0
                ),
                monochromeColor: .labelColor,
                neutralColor: .secondaryLabelColor
            )
        }
        if popoverPresenter.isShown {
            popoverPresenter.update(SidebarWorkspaceStatusPopoverModel(
                inferred: inferredStatus,
                activeOverride: hasOverride ? effectiveStatus : nil
            ))
        }
    }

    func teardown() {
        popoverPresenter.close()
        statusButton.onClick = nil
        workspace = nil
    }

    private func toggleStatusPopover() {
        if popoverPresenter.isShown {
            popoverPresenter.close()
            return
        }
        guard let workspace else { return }
        popoverPresenter.present(
            model: SidebarWorkspaceStatusPopoverModel(
                inferred: inferredStatus,
                activeOverride: hasOverride ? effectiveStatus : nil
            ),
            onSelectLane: { [weak workspace] status in
                guard let workspace else { return }
                WorkspaceTodoActions.applyStatusOverride(status, to: [workspace])
            },
            onSelectNone: { [weak workspace] in
                guard let workspace else { return }
                WorkspaceTodoActions.hideStatus(for: [workspace])
            },
            relativeTo: statusButton.bounds,
            of: statusButton,
            preferredEdge: .maxY
        )
    }
}

@MainActor
private final class WorkspaceTodoTableView: NSTableView {
    var onRowClick: ((Int, Bool) -> Void)?
    var onToggleSelectedItem: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        let row = row(at: convert(event.locationInWindow, from: nil))
        let wasSelected = selectedRow == row && row >= 0
        super.mouseDown(with: event)
        if row >= 0 {
            onRowClick?(row, wasSelected)
        }
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let isPlainReturn = (event.keyCode == 36 || event.keyCode == 76) && flags.isEmpty
        let shortcut = KeyboardShortcutSettings.shortcut(for: .toggleChecklistItemComplete)
        if isPlainReturn || shortcut.matches(event: event) {
            onToggleSelectedItem?()
            return
        }
        super.keyDown(with: event)
    }
}

@MainActor
private final class WorkspaceTodoPaneItemCellView: NSTableCellView {
    private let checkbox = PanelHeaderNativeButton(systemName: "square", label: "")
    private let textLabel = NSTextField(wrappingLabelWithString: "")
    private let attachmentButton = SidebarRowChecklistAttachmentButton()
    private var editField: FocusGrabbingTextField?
    private var editBridge: WorkspaceTodoMultilineFieldBridge?
    private var item: WorkspaceChecklistItem?
    private var onBeginEdit: (() -> Void)?
    private var onMarkInProgress: (() -> Void)?
    private var onRemove: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        checkbox.translatesAutoresizingMaskIntoConstraints = true
        textLabel.font = WorkspaceTodoPanelNativeViewController.itemFont
        textLabel.maximumNumberOfLines = 0
        textLabel.lineBreakMode = .byWordWrapping
        textLabel.isSelectable = false
        addSubview(checkbox)
        addSubview(textLabel)
        addSubview(attachmentButton)
        setAccessibilityIdentifier("WorkspaceTodoPaneItemRow")
    }

    convenience init() {
        self.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        let checkboxSize = NSSize(width: 20, height: 20)
        let attachmentSize = attachmentButton.intrinsicContentSize
        checkbox.frame = NSRect(
            x: 6,
            y: max(2, bounds.height - checkboxSize.height - 4),
            width: checkboxSize.width,
            height: checkboxSize.height
        )
        attachmentButton.frame = NSRect(
            x: bounds.width - attachmentSize.width - 6,
            y: max(2, bounds.height - attachmentSize.height - 4),
            width: attachmentSize.width,
            height: attachmentSize.height
        )
        let textFrame = NSRect(
            x: 33,
            y: 4,
            width: max(20, attachmentButton.frame.minX - 39),
            height: max(20, bounds.height - 8)
        )
        textLabel.frame = textFrame
        editField?.frame = textFrame
    }

    private func resetForReuse() {
        checkbox.actionClosure = nil
        attachmentButton.resetForReuse()
        editField?.delegate = nil
        editField?.removeFromSuperview()
        editField = nil
        editBridge = nil
        item = nil
        onBeginEdit = nil
        onMarkInProgress = nil
        onRemove = nil
    }

    func configure(
        item: WorkspaceChecklistItem,
        isEditing: Bool,
        editingText: String,
        onToggle: @escaping () -> Void,
        onEditChange: @escaping (String) -> Void,
        onCommitEdit: @escaping (String) -> Void,
        onCancelEdit: @escaping () -> Void,
        onBeginEdit: @escaping () -> Void,
        onMarkInProgress: @escaping () -> Void,
        onRemove: @escaping () -> Void,
        onAddAttachments: @escaping (UUID) -> Void,
        onRemoveAttachment: @escaping (UUID, UUID) -> Void,
        onOpenAttachments: @escaping (UUID, UUID?) -> Void
    ) {
        if self.item?.id != item.id {
            resetForReuse()
        }
        self.item = item
        self.onBeginEdit = onBeginEdit
        self.onMarkInProgress = onMarkInProgress
        self.onRemove = onRemove
        let completed = item.state == .completed
        let symbol: String
        switch item.state {
        case .pending: symbol = "square"
        case .inProgress: symbol = "minus.square"
        case .completed: symbol = "checkmark.square.fill"
        }
        checkbox.update(
            systemName: symbol,
            label: completed
                ? String(localized: "sidebar.checklist.uncheckTooltip", defaultValue: "Mark as pending")
                : String(localized: "sidebar.checklist.checkTooltip", defaultValue: "Mark as completed")
        )
        checkbox.contentTintColor = completed ? .secondaryLabelColor : .labelColor
        checkbox.actionClosure = onToggle
        let attributes: [NSAttributedString.Key: Any] = completed
            ? [
                .font: WorkspaceTodoPanelNativeViewController.itemFont,
                .foregroundColor: NSColor.secondaryLabelColor.withAlphaComponent(0.6),
                .strikethroughStyle: NSUnderlineStyle.single.rawValue,
            ]
            : [
                .font: WorkspaceTodoPanelNativeViewController.itemFont,
                .foregroundColor: NSColor.labelColor,
            ]
        textLabel.attributedStringValue = NSAttributedString(string: item.text, attributes: attributes)
        textLabel.isHidden = isEditing
        attachmentButton.configure(
            item: item,
            iconPointSize: 11,
            countFontSize: 12,
            color: .secondaryLabelColor,
            addAttachments: onAddAttachments,
            removeAttachment: onRemoveAttachment,
            openAttachments: onOpenAttachments
        )
        reconcileEditor(
            item: item,
            isEditing: isEditing,
            editingText: editingText,
            onChange: onEditChange,
            onCommit: onCommitEdit,
            onCancel: onCancelEdit
        )
        needsLayout = true
    }

    func focusEditor() {
        guard let editField else { return }
        _ = window?.makeFirstResponder(editField)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let item, let onBeginEdit, let onRemove else { return nil }
        let menu = NSMenu()
        menu.addItem(SidebarRowClosureMenuItem(
            title: String(localized: "sidebar.checklist.editItem", defaultValue: "Edit"),
            handler: onBeginEdit
        ))
        if item.state != .inProgress, let onMarkInProgress {
            menu.addItem(SidebarRowClosureMenuItem(
                title: String(
                    localized: "sidebar.checklist.markInProgress",
                    defaultValue: "Mark In Progress"
                ),
                handler: onMarkInProgress
            ))
        }
        menu.addItem(SidebarRowClosureMenuItem(
            title: String(localized: "sidebar.checklist.removeItem", defaultValue: "Remove"),
            handler: onRemove
        ))
        return menu
    }

    private func reconcileEditor(
        item: WorkspaceChecklistItem,
        isEditing: Bool,
        editingText: String,
        onChange: @escaping (String) -> Void,
        onCommit: @escaping (String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        guard isEditing else {
            editField?.delegate = nil
            editField?.removeFromSuperview()
            editField = nil
            editBridge = nil
            return
        }
        if let editField {
            editBridge?.onChange = onChange
            editBridge?.onCommit = onCommit
            editBridge?.onCancel = onCancel
            if editField.stringValue != editingText, editField.currentEditor() == nil {
                editField.stringValue = editingText
            }
            return
        }
        let field = FocusGrabbingTextField(string: editingText)
        field.selectsAllOnFocus = true
        configureMultilineField(field)
        field.placeholderString = String(
            localized: "sidebar.checklist.editItemPlaceholder",
            defaultValue: "Item text"
        )
        field.setAccessibilityIdentifier("WorkspaceTodoPaneEditItemField")
        let bridge = WorkspaceTodoMultilineFieldBridge(mode: .edit)
        bridge.onChange = onChange
        bridge.onCommit = onCommit
        bridge.onCancel = onCancel
        field.delegate = bridge
        editBridge = bridge
        editField = field
        addSubview(field)
    }
}

@MainActor
private final class WorkspaceTodoAddFieldNativeView: NSView {
    private let plusIcon = NSImageView()
    private let field = NSTextField()
    private let bridge = WorkspaceTodoMultilineFieldBridge(mode: .add)
    private(set) var preferredHeight: CGFloat = 36
    var onCommit: ((String) -> Void)?
    var onCancel: (() -> Void)?
    var onHeightChange: ((CGFloat) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        plusIcon.image = RenderableSystemSymbol.configuredAppKitImage(
            systemName: "plus.circle",
            pointSize: 13,
            weight: .regular
        )
        plusIcon.contentTintColor = .secondaryLabelColor
        plusIcon.translatesAutoresizingMaskIntoConstraints = false
        field.translatesAutoresizingMaskIntoConstraints = false
        configureMultilineField(field)
        field.placeholderString = String(
            localized: "sidebar.checklist.addItemPlaceholder",
            defaultValue: "New checklist item"
        )
        field.setAccessibilityIdentifier("WorkspaceTodoPaneAddItemField")
        field.delegate = bridge
        bridge.onChange = { [weak self] text in self?.updateHeight(for: text) }
        bridge.onCommit = { [weak self] text in self?.onCommit?(text) }
        bridge.onCancel = { [weak self] in self?.onCancel?() }
        addSubview(plusIcon)
        addSubview(field)
        NSLayoutConstraint.activate([
            plusIcon.leadingAnchor.constraint(equalTo: leadingAnchor),
            plusIcon.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            plusIcon.widthAnchor.constraint(equalToConstant: 16),
            plusIcon.heightAnchor.constraint(equalToConstant: 16),
            field.leadingAnchor.constraint(equalTo: plusIcon.trailingAnchor, constant: 7),
            field.trailingAnchor.constraint(equalTo: trailingAnchor),
            field.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            field.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func updateColors(primary: NSColor, secondary: NSColor) {
        field.textColor = primary
        (field.currentEditor() as? NSTextView)?.insertionPointColor = primary
        plusIcon.contentTintColor = secondary
    }

    func focus() {
        _ = window?.makeFirstResponder(field)
    }

    func clearAndRefocus() {
        clear()
        focus()
    }

    func clear() {
        field.stringValue = ""
        updateHeight(for: "")
    }

    func teardown() {
        field.delegate = nil
        onCommit = nil
        onCancel = nil
        onHeightChange = nil
    }

    private func updateHeight(for text: String) {
        let font = field.font ?? .systemFont(ofSize: 13)
        let width = max(80, field.bounds.width)
        let bounds = NSString(string: text.isEmpty ? " " : text).boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        )
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        let next = max(36, min(ceil(bounds.height), lineHeight * 8) + 14)
        guard next != preferredHeight else { return }
        preferredHeight = next
        onHeightChange?(next)
    }
}

@MainActor
private final class WorkspaceTodoMultilineFieldBridge: NSObject, NSTextFieldDelegate {
    enum Mode { case add, edit }

    let mode: Mode
    var onChange: ((String) -> Void)?
    var onCommit: ((String) -> Void)?
    var onCancel: (() -> Void)?
    private var explicitCompletion = false

    init(mode: Mode) {
        self.mode = mode
    }

    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        onChange?(field.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            explicitCompletion = true
            onCancel?()
            return true
        }
        guard selector == #selector(NSResponder.insertNewline(_:))
            || selector == #selector(NSResponder.insertLineBreak(_:))
            || selector == #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)) else { return false }
        let modifiers = NSApp.currentEvent?.modifierFlags.intersection(.deviceIndependentFlagsMask) ?? []
        let shouldCommit = mode == .add
            ? !modifiers.contains(.shift)
            : modifiers.contains(.command)
        if shouldCommit {
            explicitCompletion = true
            onCommit?(control.stringValue)
            return true
        }
        textView.insertText("\n", replacementRange: textView.selectedRange())
        control.stringValue = textView.string
        onChange?(control.stringValue)
        return true
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard !explicitCompletion,
              let field = obj.object as? NSTextField else {
            explicitCompletion = false
            return
        }
        let text = field.stringValue
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            onCancel?()
        } else {
            onCommit?(text)
        }
        explicitCompletion = false
    }
}

@MainActor
private final class WorkspaceTodoPanelRootView: NSView {
    var onPointerDown: (() -> Void)?
    private var eventMonitor: Any?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self,
                  event.window === self.window,
                  !self.isHiddenOrHasHiddenAncestor,
                  self.bounds.contains(self.convert(event.locationInWindow, from: nil)) else { return event }
            Task { @MainActor [weak self] in
                await Task.yield()
                self?.onPointerDown?()
            }
            return event
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
    }
}

@MainActor
private func configureMultilineField(_ field: NSTextField) {
    field.isBordered = false
    field.drawsBackground = false
    field.focusRingType = .none
    field.usesSingleLineMode = false
    field.cell?.usesSingleLineMode = false
    field.cell?.wraps = true
    field.cell?.isScrollable = false
    field.lineBreakMode = .byWordWrapping
    field.font = .systemFont(ofSize: 13)
    field.textColor = .labelColor
    if let focusField = field as? FocusGrabbingTextField {
        focusField.caretColor = .labelColor
    } else {
        (field.currentEditor() as? NSTextView)?.insertionPointColor = .labelColor
    }
}

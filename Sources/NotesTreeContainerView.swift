import AppKit

/// AppKit container hosting the Notes tab: a Files-style header bar (folder
/// icon + workspace path, with the tree's actions as trailing buttons), the
/// scrollable `NSOutlineView` whose top level is the notes themselves (exactly
/// like the Files tree), and a centered empty-state.
final class NotesTreeContainerView: NSView {
    let outlineView: NotesTreeOutlineView
    private let headerView: NotesTreeHeaderView
    private let scrollView = NSScrollView()
    private let emptyStack = NSStackView()
    private let emptyIcon = NSImageView()
    private let emptyLabel = NSTextField(wrappingLabelWithString: "")
    private let emptyNewNoteButton = NSButton(title: "", target: nil, action: nil)
    private weak var coordinator: NotesTreePanelView.Coordinator?

    /// The store revision currently rendered; -1 forces the first reload.
    var appliedRevision = -1

    init(coordinator: NotesTreePanelView.Coordinator) {
        self.coordinator = coordinator
        self.outlineView = NotesTreeOutlineView()
        self.headerView = NotesTreeHeaderView(coordinator: coordinator)
        super.init(frame: .zero)
        setup(coordinator: coordinator)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// While this tree is on screen, the window file-drop overlay forwards
    /// file-bearing drags over its region to the outline (note drags carry a
    /// fileURL for Finder export and the preview payload for pane drops), so
    /// notes can still be moved between folders in here.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            SidebarFileDropDeferralRegistry.unregister(outlineView)
        } else {
            SidebarFileDropDeferralRegistry.register(outlineView)
        }
    }

    private func setup(coordinator: NotesTreePanelView.Coordinator) {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("notes"))
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.rowSizeStyle = .custom
        outlineView.indentationPerLevel = FileExplorerStyle.current.indentation
        outlineView.autoresizesOutlineColumn = true
        outlineView.usesAutomaticRowHeights = false
        outlineView.backgroundColor = .clear
        outlineView.selectionHighlightStyle = .regular
        outlineView.dataSource = coordinator
        outlineView.delegate = coordinator
        outlineView.coordinator = coordinator
        outlineView.target = coordinator
        outlineView.doubleAction = #selector(NotesTreePanelView.Coordinator.handleDoubleClick(_:))
        outlineView.registerForDraggedTypes([
            NotesTreePanelView.movePasteboardType,
            NotesTreePanelView.sessionDragPasteboardType,
        ])
        outlineView.setDraggingSourceOperationMask([.move, .copy], forLocal: true)

        headerView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(headerView)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: 2, left: 0, bottom: 4, right: 0)
        scrollView.documentView = outlineView
        addSubview(scrollView)

        setupEmptyState()
        addSubview(emptyStack)

        NSLayoutConstraint.activate([
            headerView.topAnchor.constraint(equalTo: topAnchor),
            headerView.leadingAnchor.constraint(equalTo: leadingAnchor),
            headerView.trailingAnchor.constraint(equalTo: trailingAnchor),

            scrollView.topAnchor.constraint(equalTo: headerView.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            emptyStack.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyStack.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor, constant: -16),
            emptyStack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
            emptyStack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24),
        ])
    }

    // MARK: - Header

    /// Mirror the workspace path into the header (the Files-header treatment).
    /// Hidden when no local workspace is bound; the empty-state explains why.
    func updateHeader(displayPath: String, notesRootPath: String?, hasWorkspace: Bool) {
        headerView.isHidden = !hasWorkspace
        headerView.update(displayPath: displayPath, toolTip: notesRootPath)
    }

    // MARK: - Empty state

    private func setupEmptyState() {
        emptyStack.translatesAutoresizingMaskIntoConstraints = false
        emptyStack.orientation = .vertical
        emptyStack.spacing = 8
        emptyStack.alignment = .centerX
        emptyStack.isHidden = true

        emptyIcon.imageScaling = .scaleProportionallyUpOrDown
        let config = NSImage.SymbolConfiguration(pointSize: 24, weight: .light)
        emptyIcon.image = NSImage(systemSymbolName: "note.text", accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        emptyIcon.contentTintColor = .tertiaryLabelColor

        emptyLabel.alignment = .center
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.preferredMaxLayoutWidth = 200

        emptyNewNoteButton.title = String(localized: "notes.action.newNote", defaultValue: "New Note")
        emptyNewNoteButton.bezelStyle = .rounded
        emptyNewNoteButton.controlSize = .small
        emptyNewNoteButton.font = .systemFont(ofSize: 11)
        emptyNewNoteButton.target = self
        emptyNewNoteButton.action = #selector(newNoteClicked)

        emptyStack.addArrangedSubview(emptyIcon)
        emptyStack.addArrangedSubview(emptyLabel)
        emptyStack.addArrangedSubview(emptyNewNoteButton)
        emptyStack.setCustomSpacing(12, after: emptyLabel)
    }

    func updateEmptyState(hasWorkspace: Bool, isEmpty: Bool) {
        if !hasWorkspace {
            emptyLabel.stringValue = String(
                localized: "notes.empty.noWorkspace",
                defaultValue: "Open a local workspace to use Notes."
            )
            emptyNewNoteButton.isHidden = true
            emptyStack.isHidden = false
        } else if isEmpty {
            emptyLabel.stringValue = String(
                localized: "notes.empty.noNotes",
                defaultValue: "No notes yet. Notes live with this workspace; its agent sessions appear here automatically."
            )
            emptyNewNoteButton.isHidden = false
            emptyStack.isHidden = false
        } else {
            emptyStack.isHidden = true
        }
    }

    // MARK: - Empty-state action

    @objc private func newNoteClicked() {
        coordinator?.newNote(inFolder: nil)
    }
}

/// Files-style header bar for the Notes tab: folder icon plus the workspace
/// path (truncating-middle, secondary label — the `FileExplorerHeaderView`
/// treatment) with the tree's actions as trailing icon buttons, so the Notes
/// and Files tabs read identically.
final class NotesTreeHeaderView: NSView {
    private let iconView = NSImageView()
    private let pathLabel = NSTextField(labelWithString: "")
    private let actionsStack = NSStackView()
    private weak var coordinator: NotesTreePanelView.Coordinator?

    init(coordinator: NotesTreePanelView.Coordinator) {
        self.coordinator = coordinator
        super.init(frame: .zero)
        setupViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupViews() {
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.contentTintColor = .secondaryLabelColor
        let iconConfig = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
        iconView.image = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(iconConfig)

        pathLabel.translatesAutoresizingMaskIntoConstraints = false
        pathLabel.font = .systemFont(ofSize: 11, weight: .medium)
        pathLabel.textColor = .secondaryLabelColor
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.maximumNumberOfLines = 1
        pathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        actionsStack.translatesAutoresizingMaskIntoConstraints = false
        actionsStack.orientation = .horizontal
        actionsStack.spacing = 2
        actionsStack.alignment = .centerY
        actionsStack.setContentHuggingPriority(.required, for: .horizontal)
        actionsStack.setContentCompressionResistancePriority(.required, for: .horizontal)
        let buttons: [(String, String, Selector)] = [
            (
                "doc.badge.plus",
                String(localized: "notes.action.newNote", defaultValue: "New Note"),
                #selector(newNoteClicked)
            ),
            (
                "folder.badge.plus",
                String(localized: "notes.action.newFolder", defaultValue: "New Folder"),
                #selector(newFolderClicked)
            ),
            (
                "arrow.down.right.and.arrow.up.left",
                String(localized: "notes.action.collapseAll", defaultValue: "Collapse All"),
                #selector(collapseAllClicked)
            ),
            (
                "arrow.clockwise",
                String(localized: "notes.action.refresh", defaultValue: "Refresh"),
                #selector(refreshClicked)
            ),
        ]
        for (symbol, tooltip, action) in buttons {
            actionsStack.addArrangedSubview(actionButton(symbol: symbol, tooltip: tooltip, action: action))
        }

        addSubview(iconView)
        addSubview(pathLabel)
        addSubview(actionsStack)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: RightSidebarChromeMetrics.secondaryBarHeight),

            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 14),
            iconView.heightAnchor.constraint(equalToConstant: 14),

            pathLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 4),
            pathLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            actionsStack.leadingAnchor.constraint(greaterThanOrEqualTo: pathLabel.trailingAnchor, constant: 6),
            actionsStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            actionsStack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    private func actionButton(symbol: String, tooltip: String, action: Selector) -> NSButton {
        let button = NSButton()
        button.bezelStyle = .inline
        button.isBordered = false
        button.imagePosition = .imageOnly
        let config = NSImage.SymbolConfiguration(pointSize: 10, weight: .medium)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)?
            .withSymbolConfiguration(config)
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = tooltip
        button.target = self
        button.action = action
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 20),
            button.heightAnchor.constraint(equalToConstant: 18),
        ])
        return button
    }

    func update(displayPath: String, toolTip: String?) {
        pathLabel.stringValue = displayPath
        pathLabel.toolTip = toolTip ?? displayPath
    }

    @objc private func newNoteClicked() { coordinator?.newNote(inFolder: nil) }
    @objc private func newFolderClicked() { coordinator?.newFolder(inFolder: nil) }
    @objc private func collapseAllClicked() { coordinator?.collapseAll() }
    @objc private func refreshClicked() { coordinator?.refresh() }
}

/// `NSOutlineView` subclass providing the per-row context menu and the same
/// keyboard model as the Files tree (j/k/h/l + arrows, Return to open,
/// ⌘⌫ to delete, sidebar mode shortcuts).
final class NotesTreeOutlineView: NSOutlineView {
    weak var coordinator: NotesTreePanelView.Coordinator?
    private var contextNode: NotesTreeNode?

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        // Route through the AppDelegate helper (like the Files tree) so the
        // user's configured `shortcuts.when` clauses gate mode switches here
        // too, instead of the default always-allowed matcher.
        if let mode = AppDelegate.shared?.rightSidebarModeShortcut(for: event) {
            _ = AppDelegate.shared?.focusRightSidebarInActiveMainWindow(
                mode: mode,
                focusFirstItem: true,
                preferredWindow: window
            )
            return
        }
        if handleNavigationKey(event) { return }
        if isReturnKey(event), let node = selectedNode() {
            coordinator?.activate(node, in: self)
            return
        }
        if isCommandDelete(event), let node = selectedNode() {
            coordinator?.delete(node)
            return
        }
        if RightSidebarKeyboardNavigation.isPlainPrintableText(event) { return }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if handleNavigationKey(event) { return true }
        if isCommandDelete(event), let node = selectedNode() {
            coordinator?.delete(node)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    private func handleNavigationKey(_ event: NSEvent) -> Bool {
        if let delta = RightSidebarKeyboardNavigation.moveDelta(for: event) {
            moveSelection(by: delta)
            return true
        }
        if let action = RightSidebarKeyboardNavigation.disclosureAction(for: event) {
            performDisclosureAction(action)
            return true
        }
        return false
    }

    private func isReturnKey(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.intersection([.command, .control, .option]).isEmpty else { return false }
        return event.keyCode == 36 || event.keyCode == 76
    }

    private func isCommandDelete(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return flags == [.command] && event.keyCode == 51
    }

    private func selectedNode() -> NotesTreeNode? {
        guard selectedRow >= 0 else { return nil }
        return item(atRow: selectedRow) as? NotesTreeNode
    }

    private func moveSelection(by delta: Int) {
        guard numberOfRows > 0 else { return }
        let current = selectedRow >= 0 ? selectedRow : (delta >= 0 ? -1 : numberOfRows)
        let target = min(max(current + delta, 0), numberOfRows - 1)
        selectRowIndexes(IndexSet(integer: target), byExtendingSelection: false)
        scrollRowToVisible(target)
    }

    private func performDisclosureAction(_ action: RightSidebarKeyboardNavigation.DisclosureAction) {
        guard let node = selectedNode() else { return }
        switch action {
        case .expand:
            if node.isExpandable, !isItemExpanded(node) { expandItem(node) }
        case .collapse:
            if node.isExpandable, isItemExpanded(node) {
                collapseItem(node)
            } else if let parent = parent(forItem: node) {
                let parentRow = row(forItem: parent)
                if parentRow >= 0 {
                    selectRowIndexes(IndexSet(integer: parentRow), byExtendingSelection: false)
                    scrollRowToVisible(parentRow)
                }
            }
        }
    }

    // MARK: Context menu

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        let node = row >= 0 ? item(atRow: row) as? NotesTreeNode : nil
        contextNode = node
        let menu = NSMenu()

        func add(_ title: String, _ selector: Selector) {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }

        // The background (no row) gets the tree-level menu.
        guard let node else {
            add(String(localized: "notes.action.newNote", defaultValue: "New Note"), #selector(newNoteContext))
            add(String(localized: "notes.action.newFolder", defaultValue: "New Folder"), #selector(newFolderContext))
            menu.addItem(.separator())
            add(String(localized: "notes.action.collapseAll", defaultValue: "Collapse All"), #selector(collapseAllContext))
            add(String(localized: "notes.action.refresh", defaultValue: "Refresh"), #selector(refreshContext))
            return menu
        }

        switch node.kind {
        case .note:
            add(String(localized: "notes.action.open", defaultValue: "Open"), #selector(openContext))
            // Index-owned flat notes can't be renamed from the tree (their
            // body path is pinned by .cmux/notes/index.json).
            if coordinator?.canRename(node) == true {
                add(String(localized: "notes.action.rename", defaultValue: "Rename"), #selector(renameContext))
            }
            add(String(localized: "notes.action.reveal", defaultValue: "Reveal in Finder"), #selector(revealContext))
            menu.addItem(.separator())
            add(String(localized: "notes.action.delete", defaultValue: "Delete"), #selector(deleteContext))
        case .folder:
            add(String(localized: "notes.action.newNote", defaultValue: "New Note"), #selector(newNoteContext))
            add(String(localized: "notes.action.newFolder", defaultValue: "New Folder"), #selector(newFolderContext))
            add(String(localized: "notes.action.rename", defaultValue: "Rename"), #selector(renameContext))
            add(String(localized: "notes.action.reveal", defaultValue: "Reveal in Finder"), #selector(revealContext))
            menu.addItem(.separator())
            add(String(localized: "notes.action.delete", defaultValue: "Delete"), #selector(deleteContext))
        case .sessionFolder:
            add(String(localized: "notes.session.resume", defaultValue: "Resume session"), #selector(resumeContext))
            add(String(localized: "notes.action.newNote", defaultValue: "New Note"), #selector(newNoteContext))
            // Virtual session rows have no folder on disk yet — nothing to
            // reveal or delete (filing a note materializes them).
            if !node.isVirtual {
                add(String(localized: "notes.action.reveal", defaultValue: "Reveal in Finder"), #selector(revealContext))
                menu.addItem(.separator())
                add(String(localized: "notes.action.delete", defaultValue: "Delete"), #selector(deleteContext))
            }
        }
        return menu
    }

    @objc private func openContext() { if let node = contextNode { coordinator?.open(node) } }
    @objc private func resumeContext() { if let node = contextNode { coordinator?.resume(node) } }
    @objc private func renameContext() { if let node = contextNode { coordinator?.beginRename(node, in: self) } }
    @objc private func revealContext() { if let node = contextNode { coordinator?.revealInFinder(node) } }
    @objc private func deleteContext() { if let node = contextNode { coordinator?.delete(node) } }
    @objc private func newNoteContext() { coordinator?.newNote(inContext: contextNode) }
    @objc private func newFolderContext() { coordinator?.newFolder(inContext: contextNode) }
    @objc private func collapseAllContext() { coordinator?.collapseAll() }
    @objc private func refreshContext() { coordinator?.refresh() }
}

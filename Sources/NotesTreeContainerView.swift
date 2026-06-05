import AppKit

/// AppKit container hosting the Notes outline: a compact action toolbar, the
/// scrollable `NSOutlineView`, and a centered empty-state message.
final class NotesTreeContainerView: NSView {
    let outlineView: NotesTreeOutlineView
    private let scrollView = NSScrollView()
    private let emptyLabel = NSTextField(labelWithString: "")
    private weak var coordinator: NotesTreePanelView.Coordinator?

    /// The store revision currently rendered; -1 forces the first reload.
    var appliedRevision = -1

    init(coordinator: NotesTreePanelView.Coordinator) {
        self.coordinator = coordinator
        self.outlineView = NotesTreeOutlineView()
        super.init(frame: .zero)
        setup(coordinator: coordinator)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup(coordinator: NotesTreePanelView.Coordinator) {
        let toolbar = buildToolbar()
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(toolbar)

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
        outlineView.registerForDraggedTypes([NotesTreePanelView.movePasteboardType])
        outlineView.setDraggingSourceOperationMask(.move, forLocal: true)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.documentView = outlineView
        addSubview(scrollView)

        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.alignment = .center
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.lineBreakMode = .byWordWrapping
        emptyLabel.maximumNumberOfLines = 0
        emptyLabel.isHidden = true
        addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            toolbar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            toolbar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            toolbar.heightAnchor.constraint(equalToConstant: 22),

            scrollView.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 4),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
            emptyLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24),
        ])
    }

    private func buildToolbar() -> NSView {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.alignment = .centerY
        let title = NSTextField(labelWithString: String(localized: "rightSidebar.mode.notes", defaultValue: "Notes"))
        title.font = .systemFont(ofSize: 11, weight: .semibold)
        title.textColor = .secondaryLabelColor
        stack.addArrangedSubview(title)
        stack.addArrangedSubview(NSView())  // spacer
        stack.addArrangedSubview(toolbarButton(
            symbol: "square.and.pencil",
            tooltip: String(localized: "notes.action.newNote", defaultValue: "New Note"),
            action: #selector(newNoteClicked)
        ))
        stack.addArrangedSubview(toolbarButton(
            symbol: "folder.badge.plus",
            tooltip: String(localized: "notes.action.newFolder", defaultValue: "New Folder"),
            action: #selector(newFolderClicked)
        ))
        stack.addArrangedSubview(toolbarButton(
            symbol: "arrow.clockwise",
            tooltip: String(localized: "notes.action.refresh", defaultValue: "Refresh"),
            action: #selector(refreshClicked)
        ))
        return stack
    }

    private func toolbarButton(symbol: String, tooltip: String, action: Selector) -> NSButton {
        let button = NSButton()
        button.bezelStyle = .inline
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = tooltip
        button.target = self
        button.action = action
        return button
    }

    func updateEmptyState(hasWorkspace: Bool, isEmpty: Bool) {
        if !hasWorkspace {
            emptyLabel.stringValue = String(
                localized: "notes.empty.noWorkspace",
                defaultValue: "Open a local workspace to use Notes."
            )
            emptyLabel.isHidden = false
        } else if isEmpty {
            emptyLabel.stringValue = String(
                localized: "notes.empty.noNotes",
                defaultValue: "No notes yet. Use the + buttons above, or run an agent with the cmux-notes skill."
            )
            emptyLabel.isHidden = false
        } else {
            emptyLabel.isHidden = true
        }
    }

    // MARK: - Toolbar actions

    @objc private func newNoteClicked() {
        coordinator?.newNote(inFolder: coordinator?.targetFolder(forRow: outlineView.selectedRow, in: outlineView))
    }

    @objc private func newFolderClicked() {
        coordinator?.newFolder(inFolder: coordinator?.targetFolder(forRow: outlineView.selectedRow, in: outlineView))
    }

    @objc private func refreshClicked() {
        coordinator?.refresh()
    }
}

/// `NSOutlineView` subclass that builds a per-row context menu routed to the
/// Notes coordinator.
final class NotesTreeOutlineView: NSOutlineView {
    weak var coordinator: NotesTreePanelView.Coordinator?
    private var contextNode: NotesTreeNode?

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

        guard let node else {
            add(String(localized: "notes.action.newNote", defaultValue: "New Note"), #selector(newNoteContext))
            add(String(localized: "notes.action.newFolder", defaultValue: "New Folder"), #selector(newFolderContext))
            menu.addItem(.separator())
            add(String(localized: "notes.action.refresh", defaultValue: "Refresh"), #selector(refreshContext))
            return menu
        }

        switch node.kind {
        case .note:
            add(String(localized: "notes.action.open", defaultValue: "Open"), #selector(openContext))
            add(String(localized: "notes.action.reveal", defaultValue: "Reveal in Finder"), #selector(revealContext))
            menu.addItem(.separator())
            add(String(localized: "notes.action.delete", defaultValue: "Delete"), #selector(deleteContext))
        case .folder:
            add(String(localized: "notes.action.newNote", defaultValue: "New Note"), #selector(newNoteContext))
            add(String(localized: "notes.action.newFolder", defaultValue: "New Folder"), #selector(newFolderContext))
            add(String(localized: "notes.action.reveal", defaultValue: "Reveal in Finder"), #selector(revealContext))
            menu.addItem(.separator())
            add(String(localized: "notes.action.delete", defaultValue: "Delete"), #selector(deleteContext))
        case .sessionFolder:
            add(String(localized: "notes.session.resume", defaultValue: "Resume session"), #selector(resumeContext))
            add(String(localized: "notes.action.newNote", defaultValue: "New Note"), #selector(newNoteContext))
            add(String(localized: "notes.action.reveal", defaultValue: "Reveal in Finder"), #selector(revealContext))
        }
        return menu
    }

    private func folderForContext() -> String? {
        guard let node = contextNode else { return nil }
        return node.kind.isDirectory ? node.path : (node.path as NSString).deletingLastPathComponent
    }

    @objc private func openContext() { if let node = contextNode { coordinator?.open(node) } }
    @objc private func resumeContext() { if let node = contextNode { coordinator?.resume(node) } }
    @objc private func revealContext() { if let node = contextNode { coordinator?.revealInFinder(node) } }
    @objc private func deleteContext() { if let node = contextNode { coordinator?.delete(node) } }
    @objc private func newNoteContext() { coordinator?.newNote(inFolder: folderForContext()) }
    @objc private func newFolderContext() { coordinator?.newFolder(inFolder: folderForContext()) }
    @objc private func refreshContext() { coordinator?.refresh() }
}

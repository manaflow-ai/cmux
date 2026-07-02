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

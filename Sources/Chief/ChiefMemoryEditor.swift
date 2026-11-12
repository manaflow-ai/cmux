import AppKit
import CmuxChief

/// What the memory sheet's sidebar lists.
enum ChiefMemorySheetItem: Int, CaseIterable {
    case aboutYou, instructions, notes

    var title: String {
        switch self {
        case .aboutYou: ChiefMemoryStrings.sidebarAboutYou
        case .instructions: ChiefMemoryStrings.sidebarInstructions
        case .notes: ChiefMemoryStrings.sidebarNotes
        }
    }

    var symbol: String {
        switch self {
        case .aboutYou: "person.crop.circle"
        case .instructions: "list.bullet.rectangle"
        case .notes: "brain"
        }
    }

    var document: ChiefMemoryDocument? {
        switch self {
        case .aboutYou: .person
        case .instructions: .instructions
        case .notes: nil
        }
    }
}

/// Chief's memory as a two-pane sheet (P1-5; reference
/// `apps/aside/web/memory-file-browser.jpg`): About You (person.md),
/// Instructions (instructions.md) and Notes (memory.jsonl) on the left; the
/// selection on the right, Markdown rendered with its last-updated time and
/// an Edit toggle to plain text, or the notes with their source, time and a
/// ✕ to forget each. It follows the files live (``ChiefMemoryStore``), so a
/// `cmux chief memory add` shows while the sheet is open.
@MainActor
final class ChiefMemoryEditor: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private static var shown: ChiefMemoryEditor?

    private let sheet: NSWindow
    private let sidebar = NSTableView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let updatedLabel = NSTextField(labelWithString: "")
    private let editButton = NSButton(title: ChiefMemoryStrings.edit, target: nil, action: nil)
    private let documentScroll = NSScrollView()
    private let documentView = NSTextView()
    private let notesScroll = NSScrollView()
    private let notesStack = NSStackView()
    private let notesEmpty = NSTextField(wrappingLabelWithString: ChiefMemoryStrings.emptyNotes)
    private let status = NSTextField(labelWithString: "")
    private var selection: ChiefMemorySheetItem = .aboutYou
    private var editing = false
    private var theme = ChiefTheme.current()
    private var observers: [any NSObjectProtocol] = []

    private init(selecting item: ChiefMemorySheetItem) {
        sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 520),
                         styleMask: [.titled, .resizable], backing: .buffered, defer: true)
        super.init()
        selection = item
        sheet.title = ChiefMemoryStrings.sheetTitle
        sheet.minSize = NSSize(width: 560, height: 360)
        sheet.appearance = theme.appearance
        build()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: ChiefMemoryStore.didChange, object: nil,
                                            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.showSelection() } // main-proof: observer on queue: .main
        })
        // The sheet follows the terminal theme, as the transcript under it does (ChiefTheme.appearance).
        for name in [Notification.Name.ghosttyConfigDidReload, .ghosttyDefaultBackgroundDidChange] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.applyTheme() } // main-proof: observer on queue: .main
            })
        }
    }

    private func applyTheme() {
        let next = ChiefTheme.current()
        guard next != theme else { return }
        theme = next
        sheet.appearance = next.appearance
        showSelection()
    }

    // MARK: Presenting

    /// Whether the sheet is open (`chief.debug open-memory` and `close-memory`).
    static var isShown: Bool { shown != nil }

    /// Closes the open sheet, saving an edit in progress as Done would.
    static func dismiss() {
        shown?.closeSheet()
    }

    /// Opens the memory sheet on `window` (a window of its own without one),
    /// or selects `item` in the one already open.
    static func present(selecting item: ChiefMemorySheetItem, in window: NSWindow?) {
        ChiefMemoryStore.shared.start()
        if let shown {
            shown.select(item)
            shown.sheet.makeKeyAndOrderFront(nil)
            return
        }
        let editor = ChiefMemoryEditor(selecting: item)
        shown = editor
        if let window {
            window.beginSheet(editor.sheet)
        } else {
            editor.sheet.center()
            editor.sheet.makeKeyAndOrderFront(nil)
        }
        editor.select(item)
    }

    /// The settings panel's Edit About You / Edit Instructions: the sheet on
    /// that file, already editing.
    static func present(title: String, fileURL: URL, in window: NSWindow?) {
        let item: ChiefMemorySheetItem = fileURL.lastPathComponent == "instructions.md" ? .instructions : .aboutYou
        present(selecting: item, in: window)
        shown?.setEditing(true)
    }

    // MARK: Layout

    private func build() {
        let content = NSView()

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("item"))
        sidebar.addTableColumn(column)
        sidebar.headerView = nil
        sidebar.style = .sourceList
        sidebar.rowHeight = 28
        sidebar.dataSource = self
        sidebar.delegate = self
        sidebar.setAccessibilityLabel(ChiefMemoryStrings.sheetTitle)
        let sidebarScroll = NSScrollView()
        sidebarScroll.documentView = sidebar
        sidebarScroll.drawsBackground = false
        sidebarScroll.hasVerticalScroller = false
        let sidebarBox = NSVisualEffectView()
        sidebarBox.material = .sidebar
        sidebarBox.blendingMode = .behindWindow
        let divider = NSBox()
        divider.boxType = .separator

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        updatedLabel.font = .systemFont(ofSize: 11)
        updatedLabel.textColor = .secondaryLabelColor
        editButton.target = self
        editButton.action = #selector(toggleEdit)
        editButton.bezelStyle = .push
        editButton.controlSize = .small
        let headerLine = NSBox()
        headerLine.boxType = .separator

        documentView.isRichText = false
        documentView.allowsUndo = true
        documentView.drawsBackground = false
        documentView.textContainerInset = NSSize(width: 24, height: 18)
        documentView.isAutomaticQuoteSubstitutionEnabled = false
        documentView.isAutomaticDashSubstitutionEnabled = false
        documentView.autoresizingMask = [.width]
        documentView.isVerticallyResizable = true
        documentView.textContainer?.widthTracksTextView = true
        documentScroll.documentView = documentView
        documentScroll.hasVerticalScroller = true
        documentScroll.drawsBackground = false

        notesStack.orientation = .vertical
        notesStack.alignment = .leading
        notesStack.spacing = 2
        notesStack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        notesStack.translatesAutoresizingMaskIntoConstraints = false
        let notesDocument = ChiefMemoryFlippedView()
        notesDocument.translatesAutoresizingMaskIntoConstraints = false
        notesDocument.addSubview(notesStack)
        notesScroll.documentView = notesDocument
        notesScroll.hasVerticalScroller = true
        notesScroll.drawsBackground = false
        notesEmpty.font = .systemFont(ofSize: 13)
        notesEmpty.textColor = .secondaryLabelColor

        status.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        status.textColor = .systemRed
        status.isHidden = true
        let close = NSButton(title: ChiefMemoryStrings.close, target: self, action: #selector(closeSheet))
        close.keyEquivalent = "\u{1b}"
        close.bezelStyle = .push

        for view in [sidebarBox, divider, titleLabel, updatedLabel, editButton, headerLine,
                     documentScroll, notesScroll, status, close] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        sidebarScroll.translatesAutoresizingMaskIntoConstraints = false
        sidebarBox.addSubview(sidebarScroll)
        let sidebarWidth: CGFloat = 180
        NSLayoutConstraint.activate([
            sidebarBox.topAnchor.constraint(equalTo: content.topAnchor),
            sidebarBox.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            sidebarBox.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            sidebarBox.widthAnchor.constraint(equalToConstant: sidebarWidth),
            sidebarScroll.topAnchor.constraint(equalTo: sidebarBox.topAnchor, constant: 10),
            sidebarScroll.bottomAnchor.constraint(equalTo: sidebarBox.bottomAnchor),
            sidebarScroll.leadingAnchor.constraint(equalTo: sidebarBox.leadingAnchor),
            sidebarScroll.trailingAnchor.constraint(equalTo: sidebarBox.trailingAnchor),
            divider.topAnchor.constraint(equalTo: content.topAnchor),
            divider.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            divider.leadingAnchor.constraint(equalTo: sidebarBox.trailingAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),

            titleLabel.leadingAnchor.constraint(equalTo: divider.trailingAnchor, constant: 18),
            titleLabel.centerYAnchor.constraint(equalTo: editButton.centerYAnchor),
            updatedLabel.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 10),
            updatedLabel.centerYAnchor.constraint(equalTo: editButton.centerYAnchor),
            updatedLabel.trailingAnchor.constraint(equalTo: editButton.leadingAnchor, constant: -10),
            editButton.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            editButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            headerLine.topAnchor.constraint(equalTo: editButton.bottomAnchor, constant: 10),
            headerLine.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            headerLine.trailingAnchor.constraint(equalTo: content.trailingAnchor),

            documentScroll.topAnchor.constraint(equalTo: headerLine.bottomAnchor),
            documentScroll.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            documentScroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            documentScroll.bottomAnchor.constraint(equalTo: close.topAnchor, constant: -12),
            notesScroll.topAnchor.constraint(equalTo: documentScroll.topAnchor),
            notesScroll.leadingAnchor.constraint(equalTo: documentScroll.leadingAnchor),
            notesScroll.trailingAnchor.constraint(equalTo: documentScroll.trailingAnchor),
            notesScroll.bottomAnchor.constraint(equalTo: documentScroll.bottomAnchor),
            notesStack.topAnchor.constraint(equalTo: notesDocument.topAnchor),
            notesStack.leadingAnchor.constraint(equalTo: notesDocument.leadingAnchor),
            notesStack.trailingAnchor.constraint(equalTo: notesDocument.trailingAnchor),
            notesStack.bottomAnchor.constraint(equalTo: notesDocument.bottomAnchor),
            notesDocument.widthAnchor.constraint(equalTo: notesScroll.contentView.widthAnchor),

            close.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            close.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
            status.leadingAnchor.constraint(equalTo: divider.trailingAnchor, constant: 18),
            status.centerYAnchor.constraint(equalTo: close.centerYAnchor),
            status.trailingAnchor.constraint(lessThanOrEqualTo: close.leadingAnchor, constant: -8),
        ])
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        sheet.contentView = content
    }

    // MARK: Sidebar

    func numberOfRows(in tableView: NSTableView) -> Int { ChiefMemorySheetItem.allCases.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let item = ChiefMemorySheetItem(rawValue: row) else { return nil }
        let cell = NSTableCellView()
        let image = NSImageView(image: NSImage(systemSymbolName: item.symbol, accessibilityDescription: nil) ?? NSImage())
        let label = NSTextField(labelWithString: item.title)
        label.font = .systemFont(ofSize: 13)
        for view in [image, label] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(view)
        }
        cell.imageView = image
        cell.textField = label
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
            image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: 16),
            label.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 7),
            label.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -6),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let item = ChiefMemorySheetItem(rawValue: sidebar.selectedRow), item != selection else { return }
        if editing { commitEdit() }
        selection = item
        setEditing(false)
    }

    private func select(_ item: ChiefMemorySheetItem) {
        if editing, item != selection { commitEdit() }
        selection = item
        if sidebar.selectedRow != item.rawValue {
            sidebar.selectRowIndexes(IndexSet(integer: item.rawValue), byExtendingSelection: false)
        }
        setEditing(false)
    }

    // MARK: Content

    /// Renders the selection again from disk. While editing, the text the user is typing stays.
    private func showSelection() {
        titleLabel.stringValue = selection.title
        status.isHidden = true
        let memory = ChiefMemoryStore.shared.memory
        if let document = selection.document {
            documentScroll.isHidden = false
            notesScroll.isHidden = true
            editButton.isHidden = false
            editButton.title = editing ? ChiefMemoryStrings.done : ChiefMemoryStrings.edit
            let modified = memory?.modificationDate(of: document)
            updatedLabel.stringValue = modified.map { ChiefMemoryStrings.updated(ChiefMemoryStrings.relative($0)) } ?? ""
            updatedLabel.toolTip = modified.map { DateFormatter.localizedString(from: $0, dateStyle: .medium, timeStyle: .short) }
            guard !editing else { return }
            let raw = memory?.text(of: document) ?? ""
            let meaningful = ChiefMemory.meaningfulText(raw)
            documentView.isEditable = false
            documentView.isSelectable = true
            if meaningful.isEmpty {
                documentView.textStorage?.setAttributedString(NSAttributedString(
                    string: ChiefMemoryStrings.emptyDocument,
                    attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.secondaryLabelColor]))
            } else {
                documentView.textStorage?.setAttributedString(ChiefMemoryMarkdown.render(meaningful))
            }
            documentView.setAccessibilityLabel(selection.title)
        } else {
            documentScroll.isHidden = true
            notesScroll.isHidden = false
            editButton.isHidden = true
            let facts = ChiefMemoryStore.shared.recent(Int.max)
            updatedLabel.stringValue = facts.first.map { ChiefMemoryStrings.updated(ChiefMemoryStrings.relative($0.createdAt)) } ?? ""
            for view in notesStack.arrangedSubviews {
                notesStack.removeArrangedSubview(view)
                view.removeFromSuperview()
            }
            if facts.isEmpty {
                notesStack.addArrangedSubview(notesEmpty)
                notesEmpty.preferredMaxLayoutWidth = max(200, notesScroll.contentSize.width - 28)
            }
            let width = max(300, notesScroll.contentSize.width - 28)
            for fact in facts {
                let row = ChiefMemoryNoteRow(fact: fact, width: width, compact: false)
                row.onForget = { [weak self] id in
                    if ChiefMemoryStore.shared.forget(id) {
                        // The file watcher is intentionally asynchronous. Refresh the sheet
                        // from the same mutation path so the clicked X disappears immediately.
                        self?.showSelection()
                    } else {
                        self?.showFailure(ChiefMemoryStrings.forgetFailed)
                    }
                }
                row.onEdit = { [weak self] fact in self?.editNote(fact) }
                row.apply(theme)
                notesStack.addArrangedSubview(row)
            }
        }
    }

    /// Edits one note without changing its id, timestamp or source. A small
    /// alert keeps the notes list scannable while making the action discoverable
    /// beside the visible pencil affordance.
    private func editNote(_ fact: ChiefMemoryFact) {
        let alert = NSAlert()
        alert.messageText = ChiefMemoryStrings.editNote
        alert.informativeText = fact.text
        let field = NSTextField(string: fact.text)
        field.frame = NSRect(x: 0, y: 0, width: 360, height: 24)
        field.lineBreakMode = .byTruncatingTail
        field.usesSingleLineMode = true
        alert.accessoryView = field
        alert.addButton(withTitle: ChiefMemoryStrings.saveNote)
        alert.addButton(withTitle: ChiefMemoryStrings.close)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard ChiefMemoryStore.shared.update(fact.id, text: field.stringValue) else {
            showFailure(ChiefMemoryStrings.editFailed)
            return
        }
        showSelection()
    }

    // MARK: Editing

    private func setEditing(_ on: Bool) {
        guard selection.document != nil || !on else { return }
        editing = on
        if on, let document = selection.document {
            let raw = ChiefMemoryStore.shared.memory?.text(of: document) ?? ""
            documentView.isEditable = true
            documentView.textStorage?.setAttributedString(NSAttributedString(string: raw, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                .foregroundColor: NSColor.labelColor,
            ]))
            documentView.typingAttributes = [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                                             .foregroundColor: NSColor.labelColor]
            sheet.makeFirstResponder(documentView)
        }
        showSelection()
    }

    @objc private func toggleEdit() {
        if editing {
            guard commitEdit() else { return }
            setEditing(false)
        } else {
            setEditing(true)
        }
    }

    /// Writes the edited text; false (with a message) when the write failed.
    @discardableResult
    private func commitEdit() -> Bool {
        guard editing, let document = selection.document, let memory = ChiefMemoryStore.shared.memory else { return true }
        let text = documentView.string
        guard text != memory.text(of: document) else { return true }
        do {
            try memory.save(text, to: document)
            return true
        } catch {
            showFailure(ChiefStrings.memorySaveFailed)
            return false
        }
    }

    private func showFailure(_ message: String) {
        status.stringValue = message
        status.isHidden = false
        NSSound.beep()
    }

    @objc private func closeSheet() {
        guard commitEdit() else { return }
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        if let parent = sheet.sheetParent {
            parent.endSheet(sheet)
        } else {
            sheet.orderOut(nil)
        }
        Self.shown = nil
    }
}

/// A top-down document view for the notes list.
private final class ChiefMemoryFlippedView: NSView {
    override var isFlipped: Bool { true }
}

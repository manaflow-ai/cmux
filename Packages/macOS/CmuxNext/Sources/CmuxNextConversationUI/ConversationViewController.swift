import AppKit
import CmuxConversation
import Observation

/// One conversation: transcript and composer, bound to a ``ConversationModel``.
final class ConversationViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    let model: ConversationModel
    private let preparer: AttachmentPreparer
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let banner = NSTextField(labelWithString: "")
    private let input = NSTextField()
    private let attachButton = NSButton()
    private let sendButton = NSButton()
    private let stopButton = NSButton()
    private let pending = NSTextField(labelWithString: "")
    private var rows: [TranscriptRow] = []
    private var staged: [OutgoingAttachment] = []
    /// Files above this size get a heads-up before sending (never a limit).
    static let largeFileWarning: UInt64 = 200 * 1024 * 1024

    init(model: ConversationModel, preparer: AttachmentPreparer) {
        self.model = model
        self.preparer = preparer
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let root = NSView()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("row"))
        table.addTableColumn(column)
        table.headerView = nil
        table.usesAutomaticRowHeights = true
        table.selectionHighlightStyle = .none
        table.dataSource = self
        table.delegate = self
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        banner.textColor = .systemRed
        banner.isHidden = true
        input.placeholderString = ConversationStrings.placeholder
        input.delegate = self
        input.target = self
        input.action = #selector(sendClicked)
        attachButton.title = ConversationStrings.attach
        attachButton.target = self
        attachButton.action = #selector(attachClicked)
        sendButton.title = ConversationStrings.send
        sendButton.target = self
        sendButton.action = #selector(sendClicked)
        stopButton.title = ConversationStrings.stop
        stopButton.target = self
        stopButton.action = #selector(stopClicked)
        pending.textColor = .secondaryLabelColor
        pending.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        let composer = NSStackView(views: [attachButton, input, stopButton, sendButton])
        composer.orientation = .horizontal
        let stack = NSStackView(views: [banner, scroll, pending, composer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -16),
            composer.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -16),
        ])
        view = root
        observe()
        render()
    }

    /// Re-renders whenever the model's state or connection changes.
    private func observe() {
        withObservationTracking {
            _ = model.state
            _ = model.connection
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.render()
                self?.observe()
            }
        }
    }

    private func render() {
        let next = TranscriptRow.rows(model.state)
        banner.isHidden = !model.state.isDeleted
        banner.stringValue = ConversationStrings.deleted
        stopButton.isHidden = !model.state.status.isBusy
        guard next != rows else { return }
        let atBottom = scroll.contentView.bounds.maxY >= table.bounds.height - 40
        rows = next
        table.reloadData()
        if atBottom, !rows.isEmpty {
            // Automatic row heights settle on layout; scroll after it.
            table.layoutSubtreeIfNeeded()
            table.scrollRowToVisible(rows.count - 1)
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("bubble")
        let cell = tableView.makeView(withIdentifier: id, owner: self) as? BubbleCellView ?? {
            let c = BubbleCellView(frame: .zero)
            c.identifier = id
            return c
        }()
        cell.configure(rows[row])
        cell.onRemove = { [weak self] id in self?.confirmRemove(id) }
        cell.onRetry = { [weak self] id in Task { try? await self?.model.retry(id) } }
        cell.onAnswer = { [weak self] request, option in Task { try? await self?.model.answer(request, optionID: option) } }
        return cell
    }

    private func confirmRemove(_ id: ClientMessageID) {
        let alert = NSAlert()
        alert.messageText = ConversationStrings.cancelQueuedTitle
        alert.informativeText = ConversationStrings.cancelQueuedBody
        alert.addButton(withTitle: ConversationStrings.remove).hasDestructiveAction = true
        alert.addButton(withTitle: ConversationStrings.keep)
        guard let window = view.window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            Task { try? await self?.model.dequeue(id) }
        }
    }

    @objc private func attachClicked() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard let window = view.window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK else { return }
            let urls = panel.urls
            Task { @MainActor in await self?.stage(urls) }
        }
    }

    /// Prepares files for the next message (also used by the debug socket).
    func stage(_ urls: [URL]) async {
        for url in urls {
            if let a = try? await preparer.prepare(url) { staged.append(a) }
        }
        pending.stringValue = staged.map(\.name).joined(separator: ", ")
        if staged.contains(where: { $0.size > Self.largeFileWarning }), let window = view.window {
            let alert = NSAlert()
            alert.messageText = ConversationStrings.largeFileTitle
            alert.informativeText = ConversationStrings.largeFileBody
            alert.addButton(withTitle: ConversationStrings.ok)
            alert.beginSheetModal(for: window) { _ in }
        }
    }

    @objc private func sendClicked() {
        let text = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !staged.isEmpty else { return }
        model.send(text: text, attachments: staged)
        staged = []
        pending.stringValue = ""
        input.stringValue = ""
    }

    @objc private func stopClicked() {
        Task { try? await model.cancelTurn() }
    }
}

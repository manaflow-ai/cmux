public import AppKit
public import CmuxConversation

/// The agent window: conversations on the left, the open one on the right.
///
/// A deliberately simple chat (the hand-crafted GUI comes later) that
/// exercises every layer below it: conversation list, history paging,
/// instant sends, queue and removal, attachments, approvals, deletion.
public final class AgentWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private let backend: any ConversationBackend
    private let outbox: any OutboxStoring
    private let preparer: AttachmentPreparer
    private let defaultDirectory: String
    private let list = NSTableView()
    private let detail = NSView()
    private var summaries: [ConversationSummary] = []
    private var listTask: Task<Void, Never>?
    /// The open conversation's view.
    private var current: ConversationViewController?
    /// The open conversation's model.
    public var currentModel: ConversationModel? { current?.model }
    /// Conversations the backend lists.
    public var conversations: [ConversationSummary] { summaries }
    /// Settings a new conversation starts with: the last one used.
    public private(set) var lastSettings: ConversationSettings

    /// Creates the window.
    /// - Parameters:
    ///   - backend: The conversations' backend.
    ///   - outbox: Where unconfirmed messages persist.
    ///   - previewDirectory: Where image previews for uploads are written.
    ///   - defaultDirectory: The working directory new conversations start in.
    public init(backend: any ConversationBackend, outbox: any OutboxStoring, previewDirectory: URL, defaultDirectory: String) {
        self.backend = backend
        self.outbox = outbox
        self.preparer = AttachmentPreparer(previewDirectory: previewDirectory)
        self.defaultDirectory = defaultDirectory
        self.lastSettings = ConversationSettings(workingDirectory: defaultDirectory)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 640), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: true)
        window.title = ConversationStrings.windowTitle
        window.isReleasedWhenClosed = false
        super.init(window: window)
        build()
        follow()
    }

    required init?(coder: NSCoder) { nil }

    deinit { listTask?.cancel() }

    private func build() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("c"))
        list.addTableColumn(column)
        list.headerView = nil
        list.dataSource = self
        list.delegate = self
        list.target = self
        list.action = #selector(listClicked)
        let scroll = NSScrollView()
        scroll.documentView = list
        scroll.hasVerticalScroller = true
        let newButton = NSButton(title: ConversationStrings.newConversation, target: self, action: #selector(newClicked))
        let sidebar = NSStackView(views: [newButton, scroll])
        sidebar.orientation = .vertical
        sidebar.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.addArrangedSubview(sidebar)
        split.addArrangedSubview(detail)
        sidebar.widthAnchor.constraint(equalToConstant: 240).isActive = true
        window?.contentView = split
    }

    private func follow() {
        let stream = backend.conversationList()
        // task-owner: the window's lifetime; deinit cancels it
        listTask = Task { [weak self] in
            for await list in stream {
                self?.summaries = list
                self?.list.reloadData()
            }
        }
    }

    /// Opens a fresh conversation; the first message creates it.
    public func newConversation() {
        show(ConversationModel(backend: backend, conversationID: nil, settings: lastSettings, outbox: outbox, outboxKey: "new-" + UUID().uuidString))
    }

    /// Opens an existing conversation.
    /// - Parameter id: The conversation.
    public func open(_ id: ConversationID) {
        if let s = summaries.first(where: { $0.id == id }) {
            lastSettings = ConversationSettings(agent: s.agent, workingDirectory: s.workingDirectory ?? defaultDirectory)
        }
        show(ConversationModel(backend: backend, conversationID: id, settings: lastSettings, outbox: outbox, outboxKey: id.rawValue))
    }

    private func show(_ model: ConversationModel) {
        let old = current
        Task { await old?.model.stop() }
        old?.view.removeFromSuperview()
        let vc = ConversationViewController(model: model, preparer: preparer)
        current = vc
        vc.view.frame = detail.bounds
        vc.view.autoresizingMask = [.width, .height]
        detail.addSubview(vc.view)
        Task { await model.start() }
    }

    /// Stages files on the open conversation's composer (debug socket).
    /// - Parameter urls: Local files.
    public func stage(_ urls: [URL]) async {
        await current?.stage(urls)
    }

    @objc private func newClicked() { newConversation() }

    @objc private func listClicked() {
        let row = list.clickedRow
        guard summaries.indices.contains(row) else { return }
        open(summaries[row].id)
    }

    public func numberOfRows(in tableView: NSTableView) -> Int { summaries.count }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let s = summaries[row]
        let label = NSTextField(labelWithString: (s.title ?? s.name) + "  \u{00B7}  " + (s.agent ?? ""))
        label.lineBreakMode = .byTruncatingTail
        label.textColor = s.status == .deleted ? .systemRed : (s.status.isBusy ? .labelColor : .secondaryLabelColor)
        return label
    }
}

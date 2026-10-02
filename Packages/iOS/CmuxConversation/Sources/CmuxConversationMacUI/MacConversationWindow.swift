#if os(macOS)
import AppKit
import CmuxConversationCore

/// One conversation the window can show: its store and its transcript.
@MainActor
final class MacConversationEntry {
    let id: String
    let store: ConversationStore
    lazy var controller = MacConversationViewController(store: store)

    init(id: String, endpoint: URL) {
        self.id = id
        store = ConversationStore(backend: ConversationSimBackend(endpoint: endpoint))
    }
}

/// macOS Messages window: a sidebar of conversations, the transcript under a
/// transparent toolbar (so the system draws the soft scroll edge effect), and
/// the composer as the content item's bottom accessory.
@MainActor
final class MacConversationSplitController: NSSplitViewController, NSToolbarDelegate {
    let entries: [MacConversationEntry]
    private let sidebar: MacConversationListViewController
    private let content = MacConversationContainerController()
    /// The bottom accessory hosting the composer (macOS 26); earlier systems pin it in the content view.
    private var composerAccessory: NSViewController?
    private let composerHost = MacFlippedView()
    private lazy var composerHeight = composerHost.heightAnchor.constraint(equalToConstant: 51)
    private let titleView = MacToolbarTitleView()
    var titleNameLabel: NSTextField { titleView.nameLabel }
    private var contentItem: NSSplitViewItem!
    private(set) var selected: MacConversationEntry?

    init(entries: [MacConversationEntry]) {
        self.entries = entries
        sidebar = MacConversationListViewController(entries: entries)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        sidebar.onSelect = { [weak self] entry in self?.select(entry) }
        // Every conversation stays live so the sidebar previews update.
        for entry in entries { entry.store.start() }
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 240
        sidebarItem.maximumThickness = 420
        sidebarItem.canCollapse = true
        addSplitViewItem(sidebarItem)

        contentItem = NSSplitViewItem(viewController: content)
        contentItem.minimumThickness = 360
        composerHeight.isActive = true
        if #available(macOS 26.0, *) {
            contentItem.automaticallyAdjustsSafeAreaInsets = true
            let accessory = NSSplitViewItemAccessoryViewController()
            accessory.view = composerHost
            contentItem.addBottomAlignedAccessoryViewController(accessory)
            composerAccessory = accessory
        } else {
            composerHost.autoresizingMask = [.width, .maxYMargin]
            content.view.addSubview(composerHost)
        }
        addSplitViewItem(contentItem)
        splitView.dividerStyle = .thin
        if let first = entries.first { select(first) }
    }

    private var didSetInitialSidebarWidth = false

    override func viewDidAppear() {
        super.viewDidAppear()
        guard !didSetInitialSidebarWidth else { return }
        didSetInitialSidebarWidth = true
        // Measured: Messages' sidebar glass panel ends 328 pt from the window edge.
        splitView.setPosition(328, ofDividerAt: 0)
    }

    func select(_ entry: MacConversationEntry) {
        selected = entry
        sidebar.markSelected(entry.id)
        let controller = entry.controller
        controller.onInfoChange = { [weak self, weak entry] info, meID, connected in
            guard let self, let entry, self.selected === entry else { return }
            self.titleView.configure(info: info, meID: meID, connected: connected)
        }
        controller.onComposerHeightChange = { [weak self] in self?.layoutComposer() }
        content.show(controller)
        composerHost.subviews.forEach { $0.removeFromSuperview() }
        composerHost.addSubview(controller.composer)
        layoutComposer()
        if let info = entry.store.info {
            titleView.configure(info: info, meID: entry.store.meID, connected: entry.store.connection == .connected)
        }
        view.window?.makeFirstResponder(controller.composer.textView)
    }

    private func layoutComposer() {
        guard let composer = selected?.controller.composer else { return }
        let height = composer.preferredHeight
        composerHeight.constant = height
        composerHost.frame.size.height = height
        composerAccessory?.view.frame.size.height = height
        if composerAccessory == nil {
            composerHost.frame = CGRect(x: 0, y: content.view.bounds.height - height, width: content.view.bounds.width, height: height)
        }
        composer.frame = CGRect(x: 0, y: 0, width: composerHost.bounds.width, height: height)
        composer.autoresizingMask = [.width]
        composerHost.needsLayout = true
        view.needsLayout = true
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        if let composer = selected?.controller.composer {
            composer.frame = CGRect(x: 0, y: 0, width: composerHost.bounds.width, height: composer.preferredHeight)
        }
    }

    // MARK: Toolbar

    static let filterItem = NSToolbarItem.Identifier("conversation.filter")
    static let composeItem = NSToolbarItem.Identifier("conversation.compose")
    static let titleItem = NSToolbarItem.Identifier("conversation.title")
    static let videoItem = NSToolbarItem.Identifier("conversation.video")

    func makeToolbar() -> NSToolbar {
        let toolbar = NSToolbar(identifier: "cmux.conversation")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.centeredItemIdentifiers = [Self.titleItem]
        return toolbar
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.filterItem, .sidebarTrackingSeparator, Self.composeItem, .flexibleSpace, Self.titleItem, .flexibleSpace, Self.videoItem]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: identifier)
        switch identifier {
        case Self.filterItem:
            item.image = NSImage(systemSymbolName: "line.3.horizontal.decrease", accessibilityDescription: nil)
            item.label = String(localized: "conversation.toolbar.filter", defaultValue: "Filter", bundle: .module)
            item.isBordered = false
            if #available(macOS 26.0, *) { item.style = .plain }
        case Self.composeItem:
            item.image = NSImage(systemSymbolName: "square.and.pencil", accessibilityDescription: nil)
            item.label = String(localized: "conversation.toolbar.compose", defaultValue: "New Message", bundle: .module)
            item.isBordered = false
            if #available(macOS 26.0, *) { item.style = .plain }
        case Self.videoItem:
            item.image = NSImage(systemSymbolName: "video", accessibilityDescription: nil)
            item.label = String(localized: "conversation.header.action", defaultValue: "Call", bundle: .module)
            item.isBordered = false
            if #available(macOS 26.0, *) { item.style = .plain }
        case Self.titleItem:
            item.view = titleView
            item.label = ""
            item.isBordered = false
            if #available(macOS 26.0, *) { item.style = .plain }
        default:
            return nil
        }
        return item
    }
}

/// Hosts the selected conversation's transcript.
@MainActor
final class MacConversationContainerController: NSViewController {
    private var current: NSViewController?

    override func loadView() {
        view = MacFlippedView(frame: NSRect(x: 0, y: 0, width: 760, height: 700))
    }

    func show(_ controller: NSViewController) {
        guard controller !== current else { return }
        current?.view.removeFromSuperview()
        current?.removeFromParent()
        addChild(controller)
        controller.view.frame = view.bounds
        controller.view.autoresizingMask = [.width, .height]
        view.addSubview(controller.view)
        current = controller
    }
}

/// The centered toolbar item: up to three avatars on a faint disc for a
/// group (one avatar for a 1:1 chat). The name sits below, in a title-bar
/// accessory, exactly as Messages stacks them.
final class MacToolbarTitleView: MacFlippedView {
    private let disc = MacFlippedView()
    private var avatars: [MacAvatarView] = []
    let nameLabel = makeMacLabel()

    override init(frame: NSRect) {
        super.init(frame: NSRect(x: 0, y: 0, width: 44, height: 40))
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 44).isActive = true
        heightAnchor.constraint(equalToConstant: 40).isActive = true
        addSubview(disc)
        nameLabel.maximumNumberOfLines = 1
        nameLabel.setAccessibilityIdentifier("conversation.header.name")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(info: ConversationInfo, meID: String?, connected: Bool) {
        let others = info.participants.filter { $0.id != meID }
        let shown = info.kind == .group ? Array(others.prefix(3)) : Array(others.prefix(1))
        avatars.forEach { $0.removeFromSuperview() }
        avatars = shown.map { participant in
            let avatar = MacAvatarView()
            avatar.initials = participant.initials
            avatar.colorHex = participant.colorHex
            avatar.layer?.borderWidth = 1
            avatar.layer?.borderColor = NSColor.black.withAlphaComponent(0.35).cgColor
            addSubview(avatar)
            return avatar
        }
        let centered = NSMutableParagraphStyle()
        centered.alignment = .center
        let title = NSMutableAttributedString(string: info.title, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .bold), .foregroundColor: NSColor.labelColor, .paragraphStyle: centered,
        ])
        title.append(NSAttributedString(string: " \u{203A}", attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.tertiaryLabelColor, .paragraphStyle: centered,
        ]))
        nameLabel.attributedStringValue = title
        nameLabel.toolTip = connected ? nil : String(localized: "conversation.header.connecting", defaultValue: "Connecting…", bundle: .module)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let cx = bounds.midX
        // Measured: a faint ~40 pt disc; avatars 19, 15 and 12 pt.
        disc.frame = CGRect(x: cx - 20, y: 0, width: 40, height: 40)
        disc.layer?.cornerRadius = 20
        disc.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.05).cgColor
        disc.isHidden = avatars.count < 2
        switch avatars.count {
        case 0: break
        case 1: avatars[0].frame = CGRect(x: cx - 17, y: 3, width: 34, height: 34)
        default:
            avatars[0].frame = CGRect(x: cx - 16, y: 3, width: 19, height: 19)
            avatars[1].frame = CGRect(x: cx + 1, y: 12, width: 15, height: 15)
            if avatars.count > 2 { avatars[2].frame = CGRect(x: cx - 9, y: 24, width: 12, height: 12) }
        }
    }
}

/// The title-bar accessory below the toolbar that carries the name.
final class MacTitleNameAccessoryView: MacFlippedView {
    let label: NSTextField

    init(label: NSTextField) {
        self.label = label
        super.init(frame: NSRect(x: 0, y: 0, width: 400, height: 22))
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        label.frame = CGRect(x: 0, y: 1, width: bounds.width, height: 17)
    }
}

/// Sidebar conversation list, like the left column of Messages.
@MainActor
final class MacConversationListViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private let entries: [MacConversationEntry]
    private let table = NSTableView()
    private let search = NSSearchField()
    private let searchPill = MacFlippedView()
    var onSelect: ((MacConversationEntry) -> Void)?

    init(entries: [MacConversationEntry]) {
        self.entries = entries
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 700))
        search.placeholderString = String(localized: "conversation.sidebar.search", defaultValue: "Search", bundle: .module)
        search.isBezeled = false
        search.drawsBackground = false
        search.focusRingType = .none
        search.font = .systemFont(ofSize: 13)
        search.translatesAutoresizingMaskIntoConstraints = false
        // Measured: a 36 pt inset pill, 15% darker than the sidebar glass.
        searchPill.wantsLayer = true
        searchPill.layer?.cornerRadius = 18
        searchPill.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(searchPill)
        searchPill.addSubview(search)
        let column = NSTableColumn(identifier: .init("c"))
        table.addTableColumn(column)
        table.headerView = nil
        // Measured: 85 pt rows with hairline separators inset to the text column.
        table.rowHeight = 85
        table.intercellSpacing = .zero
        table.style = .sourceList
        table.backgroundColor = .clear
        table.dataSource = self
        table.delegate = self
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(scroll)
        NSLayoutConstraint.activate([
            searchPill.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor, constant: 0),
            searchPill.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            searchPill.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            searchPill.heightAnchor.constraint(equalToConstant: 36),
            search.leadingAnchor.constraint(equalTo: searchPill.leadingAnchor, constant: 10),
            search.trailingAnchor.constraint(equalTo: searchPill.trailingAnchor, constant: -10),
            search.centerYAnchor.constraint(equalTo: searchPill.centerYAnchor),
            scroll.topAnchor.constraint(equalTo: searchPill.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
        updateColors()
        for entry in entries {
            entry.store.addObserver { [weak self] change in
                guard let self, change != .typing else { return }
                if let index = self.entries.firstIndex(where: { $0 === entry }) {
                    self.table.reloadData(forRowIndexes: IndexSet(integer: index), columnIndexes: IndexSet(integer: 0))
                }
            }
        }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        updateColors()
    }

    private func updateColors() {
        searchPill.layer?.backgroundColor = resolved(NSColor.black.withAlphaComponent(view.effectiveAppearance.isDarkMac ? 0.15 : 0.05), in: view)
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        MacConversationListRowView()
    }

    func markSelected(_ id: String) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let view = tableView.makeView(withIdentifier: .init("r"), owner: nil) as? MacConversationListRow ?? MacConversationListRow()
        view.identifier = .init("r")
        view.configure(store: entries[row].store)
        view.hidesSeparator = tableView.selectedRow == row || tableView.selectedRow == row + 1
        return view
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = table.selectedRow
        table.enumerateAvailableRowViews { rowView, index in
            (rowView.view(atColumn: 0) as? MacConversationListRow)?.hidesSeparator = index == row || index == row - 1
        }
        guard row >= 0, row < entries.count else { return }
        onSelect?(entries[row])
    }
}

final class MacConversationListRow: MacFlippedView {
    private let avatar = MacAvatarView()
    private var cluster: [MacAvatarView] = []
    private let title = makeMacLabel()
    private let time = makeMacLabel()
    private let preview = makeMacLabel()
    private let separator = NSBox()
    private let clusterDisc = MacFlippedView()
    var hidesSeparator = false { didSet { separator.isHidden = hidesSeparator } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        separator.boxType = .separator
        addSubview(separator)
        clusterDisc.wantsLayer = true
        clusterDisc.layer?.cornerRadius = 20
        addSubview(clusterDisc)
        title.font = .systemFont(ofSize: 13, weight: .bold)
        title.maximumNumberOfLines = 1
        time.font = .systemFont(ofSize: 12)
        time.textColor = .secondaryLabelColor
        time.alignment = .right
        preview.font = .systemFont(ofSize: 12)
        preview.textColor = .secondaryLabelColor
        preview.maximumNumberOfLines = 2
        preview.lineBreakMode = .byWordWrapping
        preview.cell?.truncatesLastVisibleLine = true
        for view in [avatar, title, time, preview] { addSubview(view) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @MainActor
    func configure(store: ConversationStore) {
        let info = store.info
        title.stringValue = info?.title ?? ""
        let others = info?.participants.filter { $0.id != store.meID } ?? []
        cluster.forEach { $0.removeFromSuperview() }
        cluster = []
        clusterDisc.isHidden = info?.kind != .group
        clusterDisc.layer?.backgroundColor = NSColor(white: 0.5, alpha: 0.45).cgColor
        if info?.kind == .group {
            avatar.isHidden = true
            cluster = others.prefix(3).map { participant in
                let view = MacAvatarView()
                view.initials = participant.initials
                view.colorHex = participant.colorHex
                addSubview(view)
                return view
            }
        } else {
            avatar.isHidden = false
            avatar.initials = others.first?.initials ?? ""
            avatar.colorHex = others.first?.colorHex
        }
        if let last = store.messages.last(where: { $0.seq != nil }) {
            preview.stringValue = last.text.isEmpty ? String(localized: "conversation.quote.photo", defaultValue: "Photo", bundle: .module) : last.text
            time.stringValue = Calendar.current.isDateInToday(last.sentAt)
                ? last.sentAt.formatted(date: .omitted, time: .shortened)
                : last.sentAt.formatted(.dateTime.weekday(.wide))
        } else {
            preview.stringValue = ""
            time.stringValue = ""
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        // Measured against Messages: 85 pt rows, 40 pt avatar centered 22.5 pt
        // from the row's leading edge, text column at 56 pt, 2-line preview.
        let disc = CGRect(x: 12, y: (bounds.height - 40) / 2 - 1, width: 40, height: 40)
        avatar.frame = disc
        clusterDisc.frame = disc
        let frames = [
            CGRect(x: disc.midX - 6 - 9, y: disc.midY - 6 - 9, width: 18, height: 18),
            CGRect(x: disc.midX + 9.5 - 7, y: disc.midY + 4 - 7, width: 14, height: 14),
            CGRect(x: disc.midX - 3 - 5.5, y: disc.midY + 11 - 5.5, width: 11, height: 11),
        ]
        for (index, view) in cluster.enumerated() where index < frames.count { view.frame = frames[index] }
        time.frame = CGRect(x: bounds.width - 85, y: 16, width: 80, height: 16)
        title.frame = CGRect(x: 56, y: 15.5, width: bounds.width - 56 - 85, height: 17)
        preview.frame = CGRect(x: 56, y: 34, width: bounds.width - 61, height: 34)
        separator.frame = CGRect(x: 56, y: bounds.height - 1, width: bounds.width - 61, height: 1)
    }
}

/// Messages' selection: a lighter rounded fill instead of the accent color.
final class MacConversationListRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        let dark = effectiveAppearance.isDarkMac
        (dark ? NSColor(white: 1, alpha: 0.08) : NSColor(white: 0, alpha: 0.06)).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill()
    }

    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }
}

/// Opens the conversation lab window (DEBUG hosts and the dev runner).
@MainActor
public enum MacConversationLab {
    private static var windows: [NSWindowController] = []

    /// Reads `CMUX_UITEST_CONVERSATION_LAB` (a conversation-sim WebSocket URL).
    public static func openIfRequested(environment: [String: String] = ProcessInfo.processInfo.environment) {
        guard let raw = environment["CMUX_UITEST_CONVERSATION_LAB"], let url = URL(string: raw) else { return }
        open(endpoint: url)
    }

    /// Opens a Messages-style window with every conversation the service hosts;
    /// `endpoint`'s `conversation` query picks the initial selection.
    @discardableResult
    public static func open(endpoint: URL) -> MacConversationViewController {
        let initial = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "conversation" }?.value ?? "group"
        let ids = ["group", "direct"].sorted { lhs, _ in lhs == initial }
        let entries = ids.map { id -> MacConversationEntry in
            var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
            components.queryItems = [URLQueryItem(name: "conversation", value: id)]
            return MacConversationEntry(id: id, endpoint: components.url!)
        }
        let split = MacConversationSplitController(entries: entries)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        window.title = String(localized: "conversation.lab.title", defaultValue: "Conversation", bundle: .module)
        window.contentViewController = split
        window.toolbar = split.makeToolbar()
        let nameAccessory = NSTitlebarAccessoryViewController()
        nameAccessory.layoutAttribute = .bottom
        nameAccessory.view = MacTitleNameAccessoryView(label: split.titleNameLabel)
        nameAccessory.view.frame.size.height = 22
        if #available(macOS 26.1, *) { nameAccessory.preferredScrollEdgeEffectStyle = .soft }
        window.addTitlebarAccessoryViewController(nameAccessory)
        window.minSize = NSSize(width: 640, height: 420)
        window.setContentSize(NSSize(width: 1100, height: 760))
        window.center()
        window.identifier = .init("cmux.conversationLab")
        let windowController = NSWindowController(window: window)
        windows.append(windowController)
        windowController.showWindow(nil)
        return entries[0].controller
    }

    /// The selected conversation's controller in the frontmost lab window.
    public static var selectedController: MacConversationViewController? {
        (windows.last?.window?.contentViewController as? MacConversationSplitController)?.selected?.controller
    }

    /// Selects a conversation (`group` / `direct`) in the frontmost lab window.
    public static func select(_ id: String) {
        guard let split = windows.last?.window?.contentViewController as? MacConversationSplitController,
              let entry = split.entries.first(where: { $0.id == id }) else { return }
        split.select(entry)
    }
}
#endif

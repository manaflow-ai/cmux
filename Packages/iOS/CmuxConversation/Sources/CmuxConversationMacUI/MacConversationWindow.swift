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
        store = ConversationStore(backend: ConversationSimBackend(endpoint: endpoint), pageSize: ConversationStore.macPageSize)
    }

    init(id: String, store: ConversationStore) {
        self.id = id
        self.store = store
    }
}

/// macOS Messages window: a sidebar of conversations, the transcript under a
/// transparent toolbar (so the system draws the soft scroll edge effect), and
/// the composer as the content item's bottom accessory.
@MainActor
final class MacConversationSplitController: NSSplitViewController, NSToolbarDelegate {
    let entries: [MacConversationEntry]
    let sidebar: MacConversationListViewController
    private let content = MacConversationContainerController()
    /// The bottom accessory hosting the composer (macOS 26); earlier systems pin it in the content view.
    private var composerAccessory: NSViewController?
    private let composerHost = MacFlippedView()
    private lazy var composerHeight = composerHost.heightAnchor.constraint(equalToConstant: 51)
    private let titleView = MacToolbarTitleView()
    var titleNameLabel: NSTextField { titleView.nameLabel }
    private var contentItem: NSSplitViewItem!
    private(set) var selected: MacConversationEntry?
    /// Total unread across conversations (the Dock badge).
    private(set) lazy var unreadBadge = ConversationUnreadBadge(stores: entries.map(\.store))

    init(entries: [MacConversationEntry]) {
        self.entries = entries
        sidebar = MacConversationListViewController(entries: entries)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        // Arrowing through the list keeps focus there; a click moves it to the composer.
        sidebar.onSelect = { [weak self] entry in self?.select(entry, focusComposer: !MacKeyboardNavigation.isActive) }
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
            if #available(macOS 26.1, *) { accessory.preferredScrollEdgeEffectStyle = .soft }
            contentItem.addBottomAlignedAccessoryViewController(accessory)
            composerAccessory = accessory
            // The name strip is a soft top accessory of the transcript pane:
            // it makes AppKit's native toolbar edge effect soft (Messages' look)
            // instead of the default hard cutoff with a separator line.
            do {
                let top = NSSplitViewItemAccessoryViewController()
                // An empty strip: it only turns the toolbar's native edge soft.
                let strip = MacFlippedView()
                strip.translatesAutoresizingMaskIntoConstraints = false
                strip.heightAnchor.constraint(equalToConstant: 1).isActive = true
                top.view = strip
                if #available(macOS 26.1, *) { top.preferredScrollEdgeEffectStyle = .soft }
                contentItem.addTopAlignedAccessoryViewController(top)
            }
        } else {
            composerHost.autoresizingMask = [.width, .maxYMargin]
            content.view.addSubview(composerHost)
        }
        addSplitViewItem(contentItem)
        splitView.dividerStyle = .thin
        if let first = entries.first { select(first) }
        unreadBadge.onChange = { [weak self] in
            guard let self else { return }
            MacConversationLab.onUnreadTotalChange?(self.unreadBadge.total)
        }
        let center = NotificationCenter.default
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            center.addObserver(self, selector: #selector(viewingConditionsChanged), name: name, object: nil)
        }
    }

    private weak var viewingWindow: NSWindow?

    private func observeWindowForViewing() {
        if let window = view.window, window !== viewingWindow {
            viewingWindow = window
            let center = NotificationCenter.default
            for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification] {
                center.addObserver(self, selector: #selector(viewingConditionsChanged), name: name, object: window)
            }
            center.addObserver(self, selector: #selector(windowWillClose), name: NSWindow.willCloseNotification, object: window)
        }
        updateViewing()
    }

    @objc private func viewingConditionsChanged() {
        updateViewing()
    }

    @objc private func windowWillClose() {
        for entry in entries { entry.store.endVisit() }
    }

    /// Messages reads the selected conversation only while its window is on
    /// screen in the active app; everything else accumulates unread.
    private func updateViewing() {
        let window = view.window
        let windowShowing = window.map { $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible) } ?? false
        let active = NSApp.isActive || MacConversationLab.treatsInactiveAsViewing
        for entry in entries {
            if entry === selected {
                entry.store.setViewing(windowShowing && active)
            } else {
                entry.store.endVisit()
            }
        }
    }

    private var didSetInitialSidebarWidth = false

    override func viewDidAppear() {
        super.viewDidAppear()
        observeWindowForViewing()
        guard !didSetInitialSidebarWidth else { return }
        didSetInitialSidebarWidth = true
        // Messages opens with the message field focused.
        if let composer = selected?.controller.composer { view.window?.makeFirstResponder(composer.textView) }
        // Measured: Messages' sidebar glass panel ends 328 pt from the window edge.
        splitView.setPosition(328, ofDividerAt: 0)
    }

    func select(_ entry: MacConversationEntry, focusComposer: Bool = true) {
        selected = entry
        updateViewing()
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
        updateKeyViewLoop()
        if focusComposer { view.window?.makeFirstResponder(controller.composer.textView) }
    }

    // MARK: Keyboard navigation

    /// Tab order, as in Messages: search, conversation list, transcript, composer.
    private func updateKeyViewLoop() {
        guard let controller = selected?.controller else { return }
        sidebar.searchField.nextKeyView = sidebar.tableView
        sidebar.tableView.nextKeyView = controller.tableView
        controller.tableView.nextKeyView = controller.composer.textView
        controller.composer.textView.nextKeyView = sidebar.searchField
    }

    /// Conversation commands reach the selected conversation from anywhere
    /// in the window (the sidebar included).
    override func supplementalTarget(forAction action: Selector, sender: Any?) -> Any? {
        if let controller = selected?.controller, controller.responds(to: action) { return controller }
        return super.supplementalTarget(forAction: action, sender: sender)
    }

    /// Edit > Search > Find… (⌘F): Messages searches every conversation from the sidebar.
    @objc func searchConversations(_ sender: Any?) {
        if let item = splitViewItems.first, item.isCollapsed { item.animator().isCollapsed = false }
        view.window?.makeFirstResponder(sidebar.searchField)
    }

    /// Window > Go to Next Conversation (⌃⇥).
    @objc func selectNextConversation(_ sender: Any?) { stepConversation(by: 1) }

    /// Window > Go to Previous Conversation (⌃⇧⇥).
    @objc func selectPreviousConversation(_ sender: Any?) { stepConversation(by: -1) }

    private func stepConversation(by delta: Int) {
        let ids = sidebar.visibleIDs
        guard !ids.isEmpty else { return }
        let current = selected.flatMap { ids.firstIndex(of: $0.id) } ?? -delta
        let next = ((current + delta) % ids.count + ids.count) % ids.count
        guard let entry = entries.first(where: { $0.id == ids[next] }), entry !== selected else { return }
        let focusInSidebar = (view.window?.firstResponder as? NSView)?.isDescendant(of: sidebar.view) == true
        select(entry, focusComposer: !focusInSidebar)
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
        // Settle the accessory at its new height now, then place the pill
        // against it; otherwise a multi-line paste lays the pill out against
        // the old accessory and it stays clipped until the next keystroke.
        view.layoutSubtreeIfNeeded()
        composer.needsLayout = true
        composer.layoutSubtreeIfNeeded()
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

    /// Measured: Messages' toolbar glyphs are ~15 pt wide.
    private static let toolbarSymbol = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)

    /// Measured: Messages' compose and call controls are 36 pt Liquid Glass
    /// circles (the default toolbar glass is a capsule).
    private static func circleButton(_ symbol: String, label: String) -> NSView {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .medium)) ?? NSImage(), target: nil, action: nil)
        if #available(macOS 26.0, *) {
            button.bezelStyle = .glass
            button.borderShape = .circle
        } else {
            button.isBordered = false
        }
        button.controlSize = .large
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 36).isActive = true
        button.heightAnchor.constraint(equalToConstant: 36).isActive = true
        button.setAccessibilityLabel(label)
        return button
    }

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
        // Messages' toolbar controls are Liquid Glass buttons (the macOS 26
        // default bordered toolbar style); only the title cluster is plain.
        case Self.filterItem:
            item.image = NSImage(systemSymbolName: "line.3.horizontal.decrease", accessibilityDescription: nil)?.withSymbolConfiguration(Self.toolbarSymbol)
            item.label = String(localized: "conversation.toolbar.filter", defaultValue: "Filter", bundle: .module)
            item.isBordered = true
        case Self.composeItem:
            item.label = String(localized: "conversation.toolbar.compose", defaultValue: "New Message", bundle: .module)
            item.view = Self.circleButton("square.and.pencil", label: item.label)
        case Self.videoItem:
            item.label = String(localized: "conversation.header.action", defaultValue: "Call", bundle: .module)
            item.view = Self.circleButton("video", label: item.label)
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
    static let drop: CGFloat = 0
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
            .font: NSFont.systemFont(ofSize: 16, weight: .bold), .foregroundColor: NSColor.tertiaryLabelColor, .paragraphStyle: centered, .baselineOffset: -1,
        ]))
        nameLabel.attributedStringValue = title
        nameLabel.toolTip = connected ? nil : String(localized: "conversation.header.connecting", defaultValue: "Connecting…", bundle: .module)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let cx = bounds.midX
        // Measured against Messages: a barely visible ~36 pt dark disc behind
        // avatars of 19, 14.5 and 11.5 pt.
        disc.frame = CGRect(x: cx - 17.5, y: 4 + Self.drop, width: 36, height: 36)
        disc.layer?.cornerRadius = 18
        disc.layer?.backgroundColor = effectiveAppearance.isDarkMac ? NSColor.black.withAlphaComponent(0.12).cgColor : NSColor.black.withAlphaComponent(0.04).cgColor
        disc.isHidden = avatars.count < 2
        switch avatars.count {
        case 0: break
        case 1: avatars[0].frame = CGRect(x: cx - 17, y: 3 + Self.drop, width: 34, height: 34)
        default:
            avatars[0].frame = CGRect(x: cx - 14.25, y: 6.25 + Self.drop, width: 19, height: 19)
            avatars[1].frame = CGRect(x: cx + 3, y: 17.5 + Self.drop, width: 14.5, height: 14.5)
            if avatars.count > 2 { avatars[2].frame = CGRect(x: cx - 8, y: 26 + Self.drop, width: 11.5, height: 11.5) }
        }
    }
}

/// The title-bar accessory below the toolbar that carries the name.
final class MacTitleNameAccessoryView: MacFlippedView {
    let label: NSTextField
    /// Measured: Messages sets the name in a 26 pt Liquid Glass capsule with
    /// 12 pt of padding on each side of the text, under the avatar cluster.
    private let capsule: NSView = {
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = 13
            return glass
        }
        return NSView()
    }()
    /// Messages centers the capsule 55 pt below the window top; a titlebar
    /// accessory starts under the 52 pt toolbar and clips glass above it, so
    /// the capsule sits whole just below (about 5 pt lower).
    static let height: CGFloat = 27
    static let lift: CGFloat = 0

    init(label: NSTextField) {
        self.label = label
        super.init(frame: NSRect(x: 0, y: 0, width: 400, height: Self.height))
        addSubview(capsule)
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let textWidth = ceil(label.attributedStringValue.size().width)
        let width = textWidth + 24
        capsule.frame = CGRect(x: (bounds.width - width) / 2, y: Self.lift, width: width, height: 26)
        label.frame = CGRect(x: 0, y: Self.lift + (26 - 17) / 2, width: bounds.width, height: 17)
    }
}

/// Sidebar conversation list, like the left column of Messages: pinned
/// conversations as large avatars on top, then everything else newest first.
@MainActor
final class MacConversationListViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSMenuDelegate {
    private let entries: [MacConversationEntry]
    /// List rows as shown: unpinned conversations newest first, or every match while searching.
    private var visible: [MacConversationEntry] = []
    /// Pinned conversations in pin order (none while searching).
    private var pinned: [MacConversationEntry] = []
    /// Whether table row 0 is the pins grid.
    private var pinsRowShown = false
    /// A list row is being dragged, so an empty pins area shows "Drag here to pin".
    private var isDraggingRow = false
    private let pinsGrid = MacPinnedGridView()
    private var selectedID: String?
    /// Newest seq each conversation had while it was on screen.
    private let table = MacKeyLoopTableView()
    private let search = NSSearchField()
    var searchField: NSSearchField { search }
    var tableView: NSTableView { table }
    private let searchPill = MacFlippedView()
    private let noResults = makeMacLabel()
    private var lastTableWidth: CGFloat = 0
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
        search.delegate = self
        search.setAccessibilityIdentifier("conversation.sidebar.search")
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
        let menu = NSMenu()
        menu.delegate = self
        table.menu = menu
        table.registerForDraggedTypes([.cmuxConversationID])
        table.setDraggingSourceOperationMask(.move, forLocal: true)
        table.setDraggingSourceOperationMask([], forLocal: false)
        table.draggingDestinationFeedbackStyle = .none
        pinsGrid.onSelect = { [weak self] id in self?.selectFromPins(id) }
        pinsGrid.menuProvider = { [weak self] id in
            guard let self, let entry = self.entry(id) else { return nil }
            return self.contextMenu(for: entry)
        }
        pinsGrid.onDropAt = { [weak self] id, index in self?.dropOnPins(id, at: index) }
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
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
        noResults.stringValue = String(localized: "conversation.sidebar.noResults", defaultValue: "No Results", bundle: .module)
        noResults.font = .systemFont(ofSize: 13, weight: .semibold)
        noResults.textColor = .secondaryLabelColor
        noResults.alignment = .center
        noResults.isHidden = true
        noResults.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(noResults)
        NSLayoutConstraint.activate([
            noResults.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            noResults.topAnchor.constraint(equalTo: searchPill.bottomAnchor, constant: 40),
        ])
        view = root
        updateColors()
        (pinned, visible) = arrangement()
        pinsRowShown = !pinned.isEmpty
        for entry in entries {
            entry.store.addObserver { [weak self] change in
                guard let self, change != .typing else { return }
                self.refresh(changed: entry)
            }
        }
    }

    private func lastActivity(_ entry: MacConversationEntry) -> Date {
        entry.store.messages.last?.sentAt ?? .distantPast
    }

    private func entry(_ id: String) -> MacConversationEntry? {
        entries.first { $0.id == id }
    }

    private var query: String { search.stringValue.trimmingCharacters(in: .whitespaces) }

    /// Pins and list rows. While searching, every match is a list row.
    private func arrangement() -> (pinned: [MacConversationEntry], others: [MacConversationEntry]) {
        let query = query
        let matching = query.isEmpty ? entries : entries.filter { entry in
            let store = entry.store
            if store.info?.title.localizedCaseInsensitiveContains(query) == true { return true }
            if store.info?.participants.contains(where: { !$0.isMe && $0.name.localizedCaseInsensitiveContains(query) }) == true { return true }
            return store.messages.contains { $0.text.localizedCaseInsensitiveContains(query) }
        }
        let arranged = ConversationListArrangement.arrange(matching.map {
            ConversationListArrangement.Item(id: $0.id, state: $0.store.listState, lastActivity: lastActivity($0))
        })
        let byID = Dictionary(uniqueKeysWithValues: matching.map { ($0.id, $0) })
        let pins = arranged.pinned.compactMap { byID[$0] }
        let others = arranged.others.compactMap { byID[$0] }
        guard query.isEmpty else {
            return ([], (pins + others).sorted { lastActivity($0) > lastActivity($1) })
        }
        return (pins, others)
    }

    /// Unread: the service's read marker (a conversation stays unread until
    /// it is viewed in a foreground window or read on another device), or
    /// Mark as Unread.
    private func isUnread(_ entry: MacConversationEntry) -> Bool {
        entry.store.listState.markedUnread || entry.store.unreadCount > 0
    }

    /// An unread incoming message (past the service's read marker) mentions me.
    private func unreadMentionsMe(_ entry: MacConversationEntry) -> Bool {
        guard let meID = entry.store.meID else { return false }
        let seen = entry.store.lastReadSeq
        return entry.store.messages.reversed().prefix { ($0.seq ?? .max) > seen }.contains {
            $0.seq != nil && $0.senderID != meID && $0.mentions(participantID: meID)
        }
    }

    // MARK: Rows

    private var rowOffset: Int { pinsRowShown ? 1 : 0 }

    private func listEntry(atRow row: Int) -> MacConversationEntry? {
        let index = row - rowOffset
        return visible.indices.contains(index) ? visible[index] : nil
    }

    private func row(of id: String) -> Int? {
        visible.firstIndex { $0.id == id }.map { $0 + rowOffset }
    }

    private func refresh(changed entry: MacConversationEntry? = nil) {
        let next = arrangement()
        let showsPins = !next.pinned.isEmpty || (isDraggingRow && query.isEmpty)
        let sameShape = next.pinned.map(\.id) == pinned.map(\.id) && next.others.map(\.id) == visible.map(\.id) && showsPins == pinsRowShown
        if sameShape, let entry {
            if let row = row(of: entry.id) {
                table.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: 0))
            } else if pinned.contains(where: { $0 === entry }) {
                configurePins()
            }
            return
        }
        pinned = next.pinned
        visible = next.others
        pinsRowShown = showsPins
        noResults.isHidden = !(visible.isEmpty && !query.isEmpty)
        table.reloadData()
        syncTableSelection()
    }

    private func syncTableSelection() {
        if let selectedID, let row = row(of: selectedID) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        } else {
            table.deselectAll(nil)
        }
        pinsGrid.selectedID = selectedID
    }

    private func configurePins() {
        pinsGrid.showsDropTarget = isDraggingRow && pinned.isEmpty
        pinsGrid.configure(pinned.map { .init(id: $0.id, store: $0.store, isUnread: isUnread($0)) })
        pinsGrid.selectedID = selectedID
    }

    func controlTextDidChange(_ notification: Notification) {
        refresh()
    }

    /// Lab hook: types into the search field as a person would.
    func setSearch(_ query: String) {
        search.stringValue = query
        refresh()
    }

    /// Every listed conversation in order: pins, then list rows.
    var visibleIDs: [String] { pinned.map(\.id) + visible.map(\.id) }
    var pinnedIDs: [String] { pinned.map(\.id) }

    override func viewDidLayout() {
        super.viewDidLayout()
        updateColors()
        if pinsRowShown, table.bounds.width != lastTableWidth {
            lastTableWidth = table.bounds.width
            table.noteHeightOfRows(withIndexesChanged: IndexSet(integer: 0))
        }
    }

    private func updateColors() {
        searchPill.layer?.backgroundColor = resolved(NSColor.black.withAlphaComponent(view.effectiveAppearance.isDarkMac ? 0.15 : 0.05), in: view)
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        pinsRowShown && row == 0 ? MacPinsRowView() : MacConversationListRowView()
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard pinsRowShown, row == 0 else { return tableView.rowHeight }
        return MacPinnedGridView.height(count: pinned.count, showsDropTarget: isDraggingRow)
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        !(pinsRowShown && row == 0)
    }

    func markSelected(_ id: String) {
        selectedID = id
        if let entry = entry(id), entry.store.listState.markedUnread {
            // Opening a conversation clears Mark as Unread.
            entry.store.updateListState(.init(markedUnread: false))
        }
        // The first selection can land before the table has loaded its rows;
        // without a selected row, arrow keys in the list do nothing.
        if table.numberOfRows != visible.count + rowOffset { table.reloadData() }
        if let row = row(of: id) {
            table.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: 0))
        } else if pinsRowShown {
            configurePins()
        }
        syncTableSelection()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { visible.count + rowOffset }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if pinsRowShown, row == 0 {
            configurePins()
            return pinsGrid
        }
        guard let entry = listEntry(atRow: row) else { return nil }
        let view = tableView.makeView(withIdentifier: .init("r"), owner: nil) as? MacConversationListRow ?? MacConversationListRow()
        view.identifier = .init("r")
        view.configure(store: entry.store)
        view.isUnread = isUnread(entry)
        view.isMentioned = view.isUnread && unreadMentionsMe(entry)
        view.isMuted = entry.store.listState.muted
        view.hidesSeparator = tableView.selectedRow == row || tableView.selectedRow == row + 1 || row == visible.count - 1 + rowOffset
        return view
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = table.selectedRow
        let last = visible.count - 1 + rowOffset
        table.enumerateAvailableRowViews { rowView, index in
            (rowView.view(atColumn: 0) as? MacConversationListRow)?.hidesSeparator = index == row || index == row - 1 || index == last
        }
        guard let entry = listEntry(atRow: row), entry.id != selectedID else { return }
        selectedID = entry.id
        pinsGrid.selectedID = selectedID
        onSelect?(entry)
    }

    private func selectFromPins(_ id: String) {
        guard let entry = entry(id), id != selectedID else { return }
        selectedID = id
        syncTableSelection()
        onSelect?(entry)
    }

    // MARK: Actions

    /// The one path every list action takes (menu, swipe, drag, lab).
    func perform(_ action: MacConversationListAction, on entry: MacConversationEntry) {
        let state = entry.store.listState
        switch action {
        case .togglePin:
            if state.pinned {
                entry.store.updateListState(.init(pinned: false))
            } else {
                pin(entry, at: pinned.count)
            }
        case .toggleUnread:
            if isUnread(entry) {
                // Mark as Read: moves the shared read marker and clears Mark as Unread.
                if entry.store.unreadCount > 0 { entry.store.markNewestRead() }
                if state.markedUnread {
                    entry.store.updateListState(.init(markedUnread: false))
                } else {
                    refresh(changed: entry)
                }
            } else {
                entry.store.updateListState(.init(markedUnread: true))
            }
        case .toggleAlerts:
            entry.store.updateListState(.init(muted: !state.muted))
        case .delete:
            confirmDelete(entry)
        }
    }

    /// Pins (or moves a pin) to `index`, unless that would pass Messages' limit.
    private func pin(_ entry: MacConversationEntry, at index: Int) {
        let alreadyPinned = entry.store.listState.pinned
        guard alreadyPinned || ConversationListArrangement.canPin(pinnedCount: pinned.count) else {
            showPinLimitAlert()
            return
        }
        let current = Dictionary(uniqueKeysWithValues: pinned.compactMap { pin in pin.store.listState.pinOrder.map { (pin.id, $0) } })
        let orders = ConversationListArrangement.pinOrders(pinned: pinned.map(\.id), current: current, moving: entry.id, to: index)
        if !alreadyPinned {
            entry.store.updateListState(.init(pinned: true, pinOrder: orders[entry.id] ?? index)) { [weak self] error in
                // Pins made on another device can reach the limit first.
                if error.code == Self.pinLimitErrorCode { self?.showPinLimitAlert() }
            }
        }
        for (id, order) in orders where id != entry.id || alreadyPinned {
            self.entry(id)?.store.updateListState(.init(pinOrder: order))
        }
    }

    static let pinLimitErrorCode = -32004

    private func dropOnPins(_ id: String, at index: Int) {
        guard let entry = entry(id) else { return }
        pin(entry, at: index)
    }

    private func showPinLimitAlert() {
        let alert = NSAlert()
        alert.messageText = MacListStrings.pinLimitTitle
        alert.informativeText = MacListStrings.pinLimitMessage
        alert.addButton(withTitle: MacListStrings.ok)
        if let window = view.window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    private func confirmDelete(_ entry: MacConversationEntry) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = MacListStrings.deleteAlertTitle
        alert.informativeText = MacListStrings.deleteAlertMessage
        let delete = alert.addButton(withTitle: MacListStrings.delete)
        delete.hasDestructiveAction = true
        alert.addButton(withTitle: MacListStrings.cancel)
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self else { return }
            self.table.rowActionsVisible = false
            guard response == .alertFirstButtonReturn else { return }
            self.delete(entry)
        }
        if let window = view.window {
            alert.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(alert.runModal())
        }
    }

    /// Deletes without asking (the confirmation already happened). Messages
    /// moves the selection to the next conversation.
    func delete(_ entry: MacConversationEntry) {
        let order = visibleIDs
        entry.store.updateListState(.init(deleted: true))
        guard entry.id == selectedID, let index = order.firstIndex(of: entry.id) else { return }
        let remaining = order.filter { $0 != entry.id }
        guard !remaining.isEmpty, let next = self.entry(remaining[min(index, remaining.count - 1)]) else { return }
        selectedID = next.id
        syncTableSelection()
        onSelect?(next)
    }

    // MARK: Context menu

    private func contextMenu(for entry: MacConversationEntry) -> NSMenu {
        let menu = NSMenu()
        fillMenu(menu, for: entry)
        return menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let entry = listEntry(atRow: table.clickedRow) else { return }
        fillMenu(menu, for: entry)
    }

    /// Messages' order: Pin, Mark as Unread, Hide Alerts, Delete (red).
    private func fillMenu(_ menu: NSMenu, for entry: MacConversationEntry) {
        let state = entry.store.listState
        func item(_ title: String, _ symbol: String, _ action: MacConversationListAction) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: #selector(menuAction(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = MacListMenuTarget(id: entry.id, action: action)
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            item.identifier = .init("conversation.list.\(action.rawValue)")
            return item
        }
        menu.addItem(item(state.pinned ? MacListStrings.unpin : MacListStrings.pin, state.pinned ? "pin.slash" : "pin", .togglePin))
        menu.addItem(isUnread(entry)
            ? item(MacListStrings.markRead, "message", .toggleUnread)
            : item(MacListStrings.markUnread, "message.badge", .toggleUnread))
        // The Mac shows Hide Alerts as a checkmark toggle.
        let alerts = item(MacListStrings.hideAlerts, "bell.slash", .toggleAlerts)
        alerts.state = state.muted ? .on : .off
        menu.addItem(alerts)
        menu.addItem(.separator())
        let delete = item(MacListStrings.deleteConversation, "trash", .delete)
        delete.attributedTitle = NSAttributedString(string: MacListStrings.deleteConversation, attributes: [
            .foregroundColor: NSColor.systemRed, .font: NSFont.menuFont(ofSize: 0),
        ])
        delete.image = delete.image?.withSymbolConfiguration(.init(paletteColors: [.systemRed]))
        menu.addItem(delete)
    }

    @objc private func menuAction(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? MacListMenuTarget, let entry = entry(target.id) else { return }
        perform(target.action, on: entry)
    }

    // MARK: Swipe actions

    /// Messages: swipe left for Hide Alerts and Delete (a full swipe deletes),
    /// swipe right for Mark as Unread.
    func tableView(_ tableView: NSTableView, rowActionsForRow row: Int, edge: NSTableView.RowActionEdge) -> [NSTableViewRowAction] {
        guard let entry = listEntry(atRow: row) else { return [] }
        switch edge {
        case .trailing:
            let delete = NSTableViewRowAction(style: .destructive, title: MacListStrings.delete) { [weak self] _, _ in
                self?.perform(.delete, on: entry)
            }
            delete.image = NSImage(systemSymbolName: "trash.fill", accessibilityDescription: MacListStrings.delete)
            let muted = entry.store.listState.muted
            let alertsTitle = muted ? MacListStrings.showAlerts : MacListStrings.hideAlerts
            let alerts = NSTableViewRowAction(style: .regular, title: alertsTitle) { [weak self] _, _ in
                self?.table.rowActionsVisible = false
                self?.perform(.toggleAlerts, on: entry)
            }
            alerts.image = NSImage(systemSymbolName: muted ? "bell.fill" : "bell.slash.fill", accessibilityDescription: alertsTitle)
            // Measured on iOS 26: Hide Alerts is indigo (#5E5CE6).
            alerts.backgroundColor = .systemIndigo
            // The first trailing action sits at the edge and runs on a full swipe.
            return [delete, alerts]
        case .leading:
            let unread = isUnread(entry)
            let title = unread ? MacListStrings.readButton : MacListStrings.unreadButton
            let mark = NSTableViewRowAction(style: .regular, title: title) { [weak self] _, _ in
                self?.table.rowActionsVisible = false
                self?.perform(.toggleUnread, on: entry)
            }
            mark.image = NSImage(systemSymbolName: unread ? "message.fill" : "message.badge.filled.fill", accessibilityDescription: title)
            mark.backgroundColor = .systemBlue
            return [mark]
        @unknown default:
            return []
        }
    }

    // MARK: Drag to pin and unpin

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        guard query.isEmpty, let entry = listEntry(atRow: row) else { return nil }
        let item = NSPasteboardItem()
        item.setString(entry.id, forType: .cmuxConversationID)
        return item
    }

    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint, forRowIndexes rowIndexes: IndexSet) {
        isDraggingRow = true
        if pinned.isEmpty { refresh() } else { configurePins() }
    }

    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        isDraggingRow = false
        refresh()
    }

    func tableView(_ tableView: NSTableView, validateDrop info: any NSDraggingInfo, proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        guard let id = info.draggingPasteboard.string(forType: .cmuxConversationID), let entry = entry(id) else { return [] }
        // Dropping a pin anywhere on the list unpins it; list rows only
        // reorder by activity, so a list row dropped on the list does nothing.
        return entry.store.listState.pinned ? .move : []
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: any NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        guard let id = info.draggingPasteboard.string(forType: .cmuxConversationID), let entry = entry(id),
              entry.store.listState.pinned else { return false }
        entry.store.updateListState(.init(pinned: false))
        return true
    }

    // MARK: Lab

    func entryState(_ id: String) -> (state: ConversationListState, isUnread: Bool)? {
        entry(id).map { ($0.store.listState, isUnread($0)) }
    }

    func menuTitles(for id: String) -> [String] {
        guard let entry = entry(id) else { return [] }
        return contextMenu(for: entry).items.map { $0.isSeparatorItem ? "-" : ($0.state == .on ? "✓ " : "") + $0.title }
    }

    func swipeTitles(for id: String) -> (leading: [String], trailing: [String]) {
        guard let row = row(of: id) else { return ([], []) }
        return (
            tableView(table, rowActionsForRow: row, edge: .leading).map(\.title),
            tableView(table, rowActionsForRow: row, edge: .trailing).map(\.title)
        )
    }

    func perform(_ action: MacConversationListAction, id: String, confirm: Bool) {
        guard let entry = entry(id) else { return }
        if action == .delete, !confirm { delete(entry) } else { perform(action, on: entry) }
    }

    func movePin(_ id: String, to index: Int) {
        dropOnPins(id, at: index)
    }
}

private final class MacListMenuTarget: NSObject {
    let id: String
    let action: MacConversationListAction

    init(id: String, action: MacConversationListAction) {
        self.id = id
        self.action = action
    }
}

/// Row 0 when pins exist: no selection or separator of its own.
final class MacPinsRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {}
    override func drawSeparator(in dirtyRect: NSRect) {}
}

final class MacConversationListRow: MacFlippedView {
    private let avatar = MacAvatarView()
    private var cluster: [MacAvatarView] = []
    private let title = makeMacLabel()
    private let time = makeMacLabel()
    private let preview = makeMacLabel()
    private let separator = NSBox()
    private let clusterDisc = MacFlippedView()
    private let unreadDot = MacFlippedView()
    private let mutedGlyph = NSImageView()
    var isUnread = false { didSet { updateIndicators() } }
    /// Messages swaps the unread dot for a blue "@" when an unread message mentions me.
    var isMentioned = false { didSet { updateIndicators() } }
    /// Hide Alerts: a bell.slash in the unread dot's column (the dot wins when both apply).
    var isMuted = false { didSet { updateIndicators() } }
    private let mentionGlyph = makeMacLabel()

    private func updateIndicators() {
        unreadDot.isHidden = !isUnread || isMentioned
        mentionGlyph.isHidden = !(isUnread && isMentioned)
        mutedGlyph.isHidden = !isMuted || isUnread
    }
    /// White text on the accent-filled selection.
    var isEmphasized = false {
        didSet {
            title.textColor = isEmphasized ? .white : .labelColor
            preview.textColor = isEmphasized ? NSColor.white.withAlphaComponent(0.85) : .secondaryLabelColor
            time.textColor = isEmphasized ? NSColor.white.withAlphaComponent(0.85) : .secondaryLabelColor
            mutedGlyph.contentTintColor = isEmphasized ? NSColor.white.withAlphaComponent(0.85) : .secondaryLabelColor
        }
    }
    var hidesSeparator = false { didSet { separator.isHidden = hidesSeparator } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        separator.boxType = .separator
        addSubview(separator)
        clusterDisc.wantsLayer = true
        clusterDisc.layer?.cornerRadius = 20
        addSubview(clusterDisc)
        unreadDot.wantsLayer = true
        unreadDot.layer?.cornerRadius = 5
        unreadDot.layer?.backgroundColor = NSColor.systemBlue.cgColor
        unreadDot.isHidden = true
        unreadDot.setAccessibilityLabel(String(localized: "conversation.sidebar.unread", defaultValue: "Unread", bundle: .module))
        addSubview(unreadDot)
        mentionGlyph.stringValue = "@"
        mentionGlyph.font = .systemFont(ofSize: 13, weight: .bold)
        mentionGlyph.textColor = .systemBlue
        mentionGlyph.alignment = .center
        mentionGlyph.isHidden = true
        mentionGlyph.setAccessibilityLabel(String(localized: "conversation.sidebar.mentioned", defaultValue: "Mentioned you", bundle: .module))
        addSubview(mentionGlyph)
        mutedGlyph.image = NSImage(systemSymbolName: "bell.slash.fill", accessibilityDescription: MacListStrings.alertsHidden)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
        mutedGlyph.contentTintColor = .secondaryLabelColor
        mutedGlyph.isHidden = true
        mutedGlyph.setAccessibilityIdentifier("conversation.sidebar.muted")
        addSubview(mutedGlyph)
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
            if last.isUnsent, let info {
                preview.stringValue = MacConversationRowBuilder.unsentNotice(last, meID: store.meID, info: info)
            } else {
                preview.stringValue = last.text.isEmpty
                    ? (last.audioAttachment != nil ? MacAudioStrings.audioMessage : String(localized: "conversation.quote.photo", defaultValue: "Photo", bundle: .module))
                    : last.text
            }
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
        // Measured: a 10 pt dot centered 30 pt left of the avatar's center.
        unreadDot.frame = CGRect(x: disc.midX - 30 - 5, y: disc.midY - 5, width: 10, height: 10)
        mentionGlyph.frame = CGRect(x: disc.midX - 30 - 11, y: disc.midY - 9, width: 22, height: 17)
        mutedGlyph.frame = CGRect(x: disc.midX - 30 - 7, y: disc.midY - 7, width: 14, height: 14)
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
    private var observers: [any NSObjectProtocol] = []

    /// Messages fills the selected conversation with the accent color while
    /// the window is active, and a neutral gray when it is not.
    var isActiveSelection: Bool { isSelected && window?.isKeyWindow == true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        guard let window else { return }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.selectionStyleChanged() }
            })
        }
    }

    override var isSelected: Bool { didSet { selectionStyleChanged() } }

    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        (subview as? MacConversationListRow)?.isEmphasized = isActiveSelection
    }

    private func selectionStyleChanged() {
        needsDisplay = true
        // Early in a row's life there is no cell yet; asking throws.
        guard numberOfColumns > 0 else { return }
        (view(atColumn: 0) as? MacConversationListRow)?.isEmphasized = isActiveSelection
    }

    override func drawSelection(in dirtyRect: NSRect) {
        let dark = effectiveAppearance.isDarkMac
        if isActiveSelection {
            NSColor.controlAccentColor.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 10, dy: 0), xRadius: 10, yRadius: 10).fill()
            return
        }
        (dark ? NSColor(white: 1, alpha: 0.08) : NSColor(white: 0, alpha: 0.06)).setFill()
        // Measured: the fill is inset 10 pt from the sidebar panel's edges.
        NSBezierPath(roundedRect: bounds.insetBy(dx: 10, dy: 0), xRadius: 10, yRadius: 10).fill()
    }

    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }
}

/// Opens the conversation lab window (DEBUG hosts and the dev runner).
@MainActor
public enum MacConversationLab {
    private static var windows: [NSWindowController] = []
    /// Total unread across the lab's conversations changed (a host's Dock badge).
    public static var onUnreadTotalChange: (@MainActor (Int) -> Void)?
    /// Driven runs never activate; their selected conversation still counts as viewed.
    public static var treatsInactiveAsViewing = false

    /// Unread per conversation and in total, for lab drivers.
    public static func unreadSummary() -> String {
        guard let split = windows.last?.window?.contentViewController as? MacConversationSplitController else { return "none" }
        let parts = split.entries.map { "\($0.id)=\($0.store.unreadCount)" }
        let window = split.view.window
        let state = "window visible=\(window?.isVisible ?? false) occluded=\(!(window?.occlusionState.contains(.visible) ?? false)) active=\(NSApp.isActive)"
        return (parts + ["total=\(split.unreadBadge.total)", state]).joined(separator: " ")
    }

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
        let window = MacConversationWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.titleVisibility = .hidden
        // An opaque titlebar lets AppKit apply its native scroll edge effect to
        // the transcript under the toolbar (a transparent one disables it).
        window.titlebarAppearsTransparent = false
        window.toolbarStyle = .unified
        window.title = String(localized: "conversation.lab.title", defaultValue: "Conversation", bundle: .module)
        window.contentViewController = split
        window.toolbar = split.makeToolbar()
        do {
            let nameAccessory = NSTitlebarAccessoryViewController()
            nameAccessory.layoutAttribute = .bottom
            nameAccessory.view = MacTitleNameAccessoryView(label: split.titleNameLabel)
            nameAccessory.view.frame.size.height = MacTitleNameAccessoryView.height
            window.addTitlebarAccessoryViewController(nameAccessory)
        }
        window.minSize = NSSize(width: 640, height: 420)
        window.setContentSize(NSSize(width: 1100, height: 760))
        window.center()
        // CMUX_LAB_DISPLAY names the display the lab opens on (e.g. "LG HDR 4K").
        if let name = ProcessInfo.processInfo.environment["CMUX_LAB_DISPLAY"],
           let screen = NSScreen.screens.first(where: { $0.localizedName.localizedCaseInsensitiveContains(name) }) {
            window.setFrameOrigin(NSPoint(x: screen.visibleFrame.minX + 40, y: screen.visibleFrame.maxY - window.frame.height - 40))
        }
        window.identifier = .init("cmux.conversationLab")
        let windowController = NSWindowController(window: window)
        windows.append(windowController)
        // CMUX_LAB_HEADLESS=1 lays the window out offscreen and never orders it
        // in (fleet runs render it with `png`, needing no display or capture).
        if ProcessInfo.processInfo.environment["CMUX_LAB_HEADLESS"] != "1" { windowController.showWindow(nil) }
        return entries[0].controller
    }

    /// The selected conversation's controller in the frontmost lab window.
    public static var selectedController: MacConversationViewController? {
        (windows.last?.window?.contentViewController as? MacConversationSplitController)?.selected?.controller
    }

    /// Filters the sidebar; returns the visible conversation ids in order.
    public static func search(_ query: String) -> [String] {
        guard let split = windows.last?.window?.contentViewController as? MacConversationSplitController else { return [] }
        split.sidebar.setSearch(query)
        return split.sidebar.visibleIDs
    }

    /// Selects a conversation (`group` / `direct`) in the frontmost lab window.
    public static func select(_ id: String) {
        guard let split = windows.last?.window?.contentViewController as? MacConversationSplitController,
              let entry = split.entries.first(where: { $0.id == id }) else { return }
        split.select(entry)
    }

    private static var sidebar: MacConversationListViewController? {
        (windows.last?.window?.contentViewController as? MacConversationSplitController)?.sidebar
    }

    /// Runs a list action through the same path as the menu and swipes.
    /// `confirm: false` skips the delete alert.
    public static func listAction(_ action: MacConversationListAction, conversation id: String, confirm: Bool = true) {
        sidebar?.perform(action, id: id, confirm: confirm)
    }

    /// Pins `id` (or moves its pin) to `index`, as a drop on the pins does.
    public static func movePin(_ id: String, to index: Int) {
        sidebar?.movePin(id, to: index)
    }

    /// The sidebar as listed: pinned ids, all ids in order, and per
    /// conversation its list state, unread dot, menu and swipe titles.
    public static func listSnapshot() -> [String: Any] {
        guard let sidebar else { return [:] }
        var conversations: [String: Any] = [:]
        for id in ["group", "direct"] {
            guard let (state, unread) = sidebar.entryState(id) else { continue }
            let swipes = sidebar.swipeTitles(for: id)
            conversations[id] = [
                "pinned": state.pinned, "pinOrder": state.pinOrder as Any, "muted": state.muted,
                "markedUnread": state.markedUnread, "deleted": state.deleted, "unreadDot": unread,
                "menu": sidebar.menuTitles(for: id), "swipeLeading": swipes.leading, "swipeTrailing": swipes.trailing,
            ]
        }
        return ["pinned": sidebar.pinnedIDs, "listed": sidebar.visibleIDs, "conversations": conversations]
    }

    /// The sheet on the lab window (an alert): its texts and buttons.
    public static func sheetSummary() -> String? {
        guard let sheet = windows.last?.window?.attachedSheet, let content = sheet.contentView else { return nil }
        var texts: [String] = []
        var buttons: [String] = []
        func walk(_ view: NSView) {
            if let button = view as? NSButton, !button.title.isEmpty { buttons.append(button.title) }
            else if let field = view as? NSTextField, !field.stringValue.isEmpty { texts.append(field.stringValue) }
            view.subviews.forEach(walk)
        }
        walk(content)
        return (texts + buttons.map { "[\($0)]" }).joined(separator: " | ")
    }

    /// Clicks the sheet button titled `title`.
    @discardableResult
    public static func pressSheetButton(_ title: String) -> Bool {
        guard let content = windows.last?.window?.attachedSheet?.contentView else { return false }
        func find(_ view: NSView) -> NSButton? {
            if let button = view as? NSButton, button.title == title { return button }
            return view.subviews.lazy.compactMap(find).first
        }
        guard let button = find(content) else { return false }
        button.performClick(nil)
        return true
    }

    /// Renders the lab window's content in-process to a PNG (no screen
    /// capture permission needed). `sidebarOnly` crops to the sidebar.
    @discardableResult
    public static func renderPNG(to path: String, sidebarOnly: Bool = false) -> Bool {
        guard let window = windows.last?.window, let content = window.contentView else { return false }
        let target: NSView = sidebarOnly ? (sidebar?.view ?? content) : content
        content.layoutSubtreeIfNeeded()
        guard let rep = target.bitmapImageRepForCachingDisplay(in: target.bounds) else { return false }
        target.cacheDisplay(in: target.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: URL(fileURLWithPath: path))) != nil
    }
}
#endif


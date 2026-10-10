public import AppKit
import CmuxNextDesign
import CmuxNextIcons

/// The virtualized All chats section (cx-xub5): every coding agent chat on
/// this computer, newest first, at the bottom of the sidebar. Its header row
/// (the title, search, project filter and grouping) shows only while the
/// pointer is over the sidebar, or while a search or filter is in effect.
/// The section draws its own header: the band adds none (no `title(for:)`).
public final class SidebarChatsView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, SidebarHoverRevealing {
    public nonisolated static var contribution: String { SidebarLayoutDocument.recentsContribution }
    public static var title: String { String(localized: "sidebar.chats.title", defaultValue: "All chats", bundle: .module) }
    public static var searchPlaceholder: String { String(localized: "sidebar.chats.search", defaultValue: "Search chats", bundle: .module) }
    public static var groupLabel: String { String(localized: "sidebar.chats.group", defaultValue: "Group by", bundle: .module) }
    public static var harnessGroup: String { String(localized: "sidebar.chats.group.harness", defaultValue: "Harness", bundle: .module) }
    public static var folderGroup: String { String(localized: "sidebar.chats.group.folder", defaultValue: "Folder", bundle: .module) }
    public static var accountGroup: String { String(localized: "sidebar.chats.group.account", defaultValue: "Account", bundle: .module) }
    public static var newestGroup: String { String(localized: "sidebar.chats.group.newest", defaultValue: "Newest", bundle: .module) }
    public static var offMessage: String { String(localized: "sidebar.chats.off", defaultValue: "Chats are off. Turn them on in Settings.", bundle: .module) }
    public static var emptyMessage: String { String(localized: "sidebar.chats.empty", defaultValue: "No chats yet.", bundle: .module) }
    public static var newChatTitle: String { String(localized: "sidebar.chats.newChat", defaultValue: "New chat", bundle: .module) }

    public struct Row: Hashable, Sendable {
        public var id: String
        public var title: String
        public var harness: String
        public var brand: String?
        public var folder: String?
        public var account: String?
        public var updatedAt: Date?
        public init(id: String, title: String, harness: String, brand: String?, folder: String? = nil, account: String? = nil,
                    updatedAt: Date? = nil) {
            self.id = id; self.title = title; self.harness = harness; self.brand = brand; self.folder = folder; self.account = account
            self.updatedAt = updatedAt
        }
    }

    private enum Item {
        case header(String)
        case chat(Row)
        case message(String)
    }

    public var onOpen: ((String) -> Void)?
    /// The row design (TEMPORARY picker, ``SidebarChatsDesign``); a change redraws the rows.
    public var design = SidebarChatsDesign.tunable.value { didSet { if design != oldValue { table.reloadData() } } }
    /// The clock the Age design reads (tests pin it).
    var now: () -> Date = Date.init
    /// Open in Terminal from a row's right-click menu (the only way a chat opens in a terminal).
    public var onOpenInTerminal: ((String) -> Void)?
    /// The header's right-click menu (Hide Section); the App builds it from the registry.
    public var headerMenu: (() -> NSMenu?)?
    public private(set) var rows: [Row] = []
    /// The header row: hidden (faded out, no clicks) unless revealed.
    let header = SidebarChatsHeader()
    let titleLabel = NSTextField(labelWithString: SidebarChatsView.title)
    /// The sidebar's hover state (`setHoverRevealed`).
    private(set) var isHoverRevealed = false
    let search = NSSearchField()
    /// Icon buttons, so the header fits the narrowest sidebar: Search opens
    /// the search field in the title's place; Group by opens a menu.
    let searchButton = SidebarIconButton(symbol: "magnifyingglass", label: SidebarChatsView.searchPlaceholder)
    let groupButton = SidebarIconButton(symbol: "list.bullet.indent", label: SidebarChatsView.groupLabel)
    /// The search field shows (in the title's place) while opened or holding text.
    private(set) var isSearchOpen = false
    /// The project filter (`SidebarChatsView+ProjectFilter`) and the project it shows, nil for all.
    let filterButton = SidebarIconButton(symbol: "line.3.horizontal.decrease", label: SidebarChatsView.filterTitle)
    var selectedProject: String?
    /// The rows press themselves: one click opens a chat (``SidebarChatsTable``).
    let chatTable = SidebarChatsTable()
    private var table: NSTableView { chatTable }
    private let scroll = NSScrollView()
    private var items: [Item] = []
    private(set) var selectedGrouping: SidebarChatsGrouping = .newest
    let defaults: UserDefaults
    private let preferenceKey = "sidebar.chats.grouping"
    private let expandedKey = "sidebar.chats.expanded"
    let shareKey = "sidebar.chats.share"
    /// The open height the person dragged to (`SidebarChatsView+Resize`), nil for one third.
    var customShare: CGFloat?
    let divider = SidebarSectionDivider()
    /// The line that sets All chats apart as its own section (cx-tiwv), open or minimized.
    let topLine = HairlineView()
    var dragStartHeight: CGFloat = 0
    /// Open (the list shows, a third of the sidebar tall) or minimized to its header row, the
    /// default (Lawrence 2026-10-09). Kept per Mac.
    public private(set) var isExpanded = false
    /// The section's height changed (opened, closed): the sidebar lays its bands out again.
    public var onLayoutChange: (() -> Void)?
    private var lastEnabled = true
    private var lastReady = true

    public init(frame: NSRect = .zero, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        super.init(frame: frame)
        selectedGrouping = SidebarChatsGrouping(rawValue: defaults.string(forKey: preferenceKey) ?? "") ?? .newest
        isExpanded = defaults.bool(forKey: expandedKey)
        customShare = (defaults.object(forKey: shareKey) as? Double).map { CGFloat($0) }
        configure()
    }

    required init?(coder: NSCoder) {
        defaults = .standard
        super.init(coder: coder)
        configure()
    }

    public override var isFlipped: Bool { true }

    private func configure() {
        titleLabel.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        performWithTheme { titleLabel.textColor = Palette.textSecondary }
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setAccessibilityRole(.staticText)
        search.placeholderString = Self.searchPlaceholder
        search.controlSize = .small
        search.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        search.target = self
        search.delegate = self
        search.action = #selector(searchChanged)
        onSearchChanged = { [weak self] in
            guard let self else { return }
            self.refilter()
        }
        search.setAccessibilityLabel(Self.searchPlaceholder)
        searchButton.onPress = { [weak self] in self?.openSearch() }
        groupButton.onPress = { [weak self] in self?.showGroupingMenu() }
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("chat"))
        column.isEditable = false
        table.addTableColumn(column)
        table.headerView = nil
        table.delegate = self
        table.dataSource = self
        table.intercellSpacing = .zero
        table.usesAlternatingRowBackgroundColors = false
        table.backgroundColor = .clear
        table.style = .plain
        scroll.drawsBackground = false
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        filterButton.onPress = { [weak self] in self?.showProjectMenu() }
        header.onMenu = { [weak self] in self?.headerMenu?() }
        header.onToggle = { [weak self] in self?.toggleExpanded() }
        header.icons = [searchButton, filterButton, groupButton]
        header.searchField = search
        for control in [titleLabel, search, searchButton, filterButton, groupButton] as [NSView] { header.addSubview(control) }
        addSubview(header)
        addSubview(scroll)
        addSubview(topLine)
        installDivider()
        applyHeaderReveal(animated: false)
        update([], enabled: true, ready: true)
    }

    /// Applies the latest feed projection; NSTableView only creates visible row views.
    public func update(_ rows: [Row], enabled: Bool, ready: Bool) {
        self.rows = rows
        lastEnabled = enabled
        lastReady = ready
        let filtered = applyProjectFilter(rows)
        if !enabled {
            items = [.message(Self.offMessage)]
        } else if !ready {
            items = []
        } else {
            let query = search.stringValue
            let visible = filtered.filter { row in
                query.isEmpty || [row.title, row.harness, row.id].contains { $0.localizedStandardRange(of: query) != nil }
            }
            if visible.isEmpty { items = [.message(Self.emptyMessage)] }
            else {
                let label: ((Row) -> String?)? = switch selectedGrouping {
                case .newest: nil
                case .harness: { Self.harnessName($0.harness) }
                case .folder: { $0.folder.map { ($0 as NSString).lastPathComponent } }
                case .account: { $0.account }
                }
                items = label.map { label in Self.grouped(visible, label: { label($0) ?? Self.emptyGroup }) } ?? visible.map(Item.chat)
            }
        }
        table.reloadData()
        applyHeaderReveal(animated: false)
        needsLayout = true
    }

    /// The section's height when minimized: its header row. Open, it takes ``sidebarShare`` of
    /// the sidebar instead.
    public var preferredHeight: CGFloat { Metrics.sidebarRowHeight }

    /// Open, the section is a fixed third of the sidebar's height and its list scrolls inside.
    var sidebarShare: CGFloat? { isExpanded ? customShare ?? Self.defaultShare : nil }

    /// Opens or closes the section (a click on its header).
    public func toggleExpanded() {
        isExpanded.toggle()
        defaults.set(isExpanded, forKey: expandedKey)
        if !isExpanded, isSearchOpen || !search.stringValue.isEmpty {
            search.stringValue = ""
            isSearchOpen = false
            refilter()
        }
        applyHeaderReveal(animated: false)
        needsLayout = true
        onLayoutChange?()
    }

    // MARK: Hover header

    public func setHoverRevealed(_ revealed: Bool) {
        guard revealed != isHoverRevealed else { return }
        isHoverRevealed = revealed
        applyHeaderReveal(animated: true)
    }

    /// The header shows while hovered, and while a search or project filter
    /// is in effect (a hidden filter would leave rows missing with no sign why).
    var isHeaderRevealed: Bool {
        isExpanded && (isHoverRevealed || isSearchOpen || !search.stringValue.isEmpty || selectedProject != nil || search.currentEditor() != nil)
    }

    /// Typing in the search keeps the header shown; leaving it may hide it.
    public func controlTextDidBeginEditing(_ obj: Notification) { applyHeaderReveal(animated: true) }
    public func controlTextDidEndEditing(_ obj: Notification) {
        closeSearchIfEmpty()
        applyHeaderReveal(animated: true)
    }

    /// The title always shows; the icons fade in with the hover while the section is open.
    private func applyHeaderReveal(animated: Bool) {
        let alpha: CGFloat = isHeaderRevealed ? 1 : 0
        header.iconsRevealed = isHeaderRevealed
        scroll.isHidden = !isExpanded
        divider.isHidden = !isExpanded
        let icons = [searchButton, filterButton, groupButton] as [NSView]
        guard icons.contains(where: { $0.alphaValue != alpha }) else { return }
        if animated {
            Motion.animate(.hover, in: self) { for icon in icons { icon.animator().alphaValue = alpha } }
        } else {
            for icon in icons { icon.alphaValue = alpha }
        }
    }

    /// Applies the search, grouping or project filter again to the same rows.
    func refilter() { update(rows, enabled: lastEnabled, ready: lastReady) }

    /// The chats the list shows, in order.
    var shownChatIDs: [String] {
        items.compactMap { if case .chat(let row) = $0 { row.id } else { nil } }
    }

    static func groupTitle(_ grouping: SidebarChatsGrouping) -> String {
        switch grouping {
        case .newest: newestGroup
        case .harness: harnessGroup
        case .folder: folderGroup
        case .account: accountGroup
        }
    }

    /// A harness's product name for group headers (proper nouns; same in every language).
    static func harnessName(_ id: String) -> String {
        switch id {
        case "claude-code": String(localized: "sidebar.chats.harness.claude-code", defaultValue: "Claude Code", bundle: .module)
        case "codex": String(localized: "sidebar.chats.harness.codex", defaultValue: "Codex", bundle: .module)
        case "opencode": String(localized: "sidebar.chats.harness.opencode", defaultValue: "OpenCode", bundle: .module)
        case "pi": String(localized: "sidebar.chats.harness.pi", defaultValue: "Pi", bundle: .module)
        case "gemini": String(localized: "sidebar.chats.harness.gemini", defaultValue: "Gemini CLI", bundle: .module)
        case "cursor-agent": String(localized: "sidebar.chats.harness.cursor-agent", defaultValue: "Cursor Agent", bundle: .module)
        case "amp": String(localized: "sidebar.chats.harness.amp", defaultValue: "Amp", bundle: .module)
        default: id
        }
    }

    private static var emptyGroup: String { String(localized: "sidebar.chats.group.other", defaultValue: "Other", bundle: .module) }

    private static func grouped(_ rows: [Row], label: (Row) -> String) -> [Item] {
        var groups: [String: [Row]] = [:]
        var order: [String] = []
        for row in rows {
            let value = label(row)
            if groups[value] == nil { order.append(value) }
            groups[value, default: []].append(row)
        }
        return order.flatMap { value in [.header(value)] + (groups[value] ?? []).map(Item.chat) }
    }

    @objc private func searchChanged() { onSearchChanged?() }
    /// Group by: Newest, Harness, Folder, Account; the shown one is checked.
    func groupingMenu() -> NSMenu {
        let menu = NSMenu()
        for grouping in SidebarChatsGrouping.allCases {
            let item = NSMenuItem(title: Self.groupTitle(grouping), action: #selector(pickGrouping(_:)), keyEquivalent: "")
            item.representedObject = grouping.rawValue
            item.state = grouping == selectedGrouping ? .on : .off
            item.target = self
            menu.addItem(item)
        }
        return menu
    }

    private func showGroupingMenu() {
        groupingMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: groupButton.bounds.maxY + Metrics.space1), in: groupButton)
    }

    @objc private func pickGrouping(_ item: NSMenuItem) {
        selectedGrouping = (item.representedObject as? String).flatMap(SidebarChatsGrouping.init(rawValue:)) ?? .newest
        defaults.set(selectedGrouping.rawValue, forKey: preferenceKey)
        onSearchChanged?()
    }

    /// Search: the field takes the title's place and the keyboard.
    func openSearch() {
        isSearchOpen = true
        needsLayout = true
        layoutSubtreeIfNeeded()
        window?.makeFirstResponder(search)
        applyHeaderReveal(animated: true)
    }

    /// The field closes when it is empty and editing ends (Escape, a click elsewhere).
    private func closeSearchIfEmpty() {
        guard isSearchOpen, search.stringValue.isEmpty, search.currentEditor() == nil else { return }
        isSearchOpen = false
        needsLayout = true
    }

    private var onSearchChanged: (() -> Void)? {
        get { _onSearchChanged }
        set { _onSearchChanged = newValue }
    }
    private var _onSearchChanged: (() -> Void)?

    public override func layout() {
        super.layout()
        let top = Metrics.sidebarRowHeight
        let controlHeight: CGFloat = 20
        let y = (top - controlHeight) / 2
        header.frame = NSRect(x: 0, y: 0, width: bounds.width, height: top)
        divider.frame = NSRect(x: 0, y: 0, width: bounds.width, height: Metrics.space2)
        topLine.frame = NSRect(x: 0, y: 0, width: bounds.width, height: Metrics.lineWidth(Metrics.dividerThickness))
        // Trailing icon buttons (group, filter, search), then the title or the open search field.
        let searching = isSearchOpen || !search.stringValue.isEmpty
        var x = bounds.width - Metrics.space2
        let buttons = [groupButton] + (filterButton.isHidden ? [] : [filterButton]) + (searching ? [] : [searchButton])
        for button in buttons {
            x -= controlHeight
            button.frame = NSRect(x: x, y: y, width: controlHeight, height: controlHeight)
            x -= Metrics.space1
        }
        searchButton.isHidden = searching
        search.isHidden = !searching
        titleLabel.isHidden = searching
        let leading = Metrics.space3
        let room = max(0, x - Metrics.space1 - leading)
        let titleHeight = titleLabel.intrinsicContentSize.height
        let titleWidth = ceil(titleLabel.cell?.cellSize.width ?? titleLabel.intrinsicContentSize.width)
        titleLabel.frame = NSRect(x: leading, y: (top - titleHeight) / 2, width: min(titleWidth, isExpanded ? room : bounds.width - leading), height: titleHeight)
        search.frame = NSRect(x: leading, y: y, width: room, height: controlHeight)
        scroll.frame = NSRect(x: 0, y: top, width: bounds.width, height: max(0, bounds.height - top))
    }

    public func numberOfRows(in tableView: NSTableView) -> Int { items.count }
    /// A click opens a chat (the row presses itself); nothing stays selected.
    public func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }
    public func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { Metrics.sidebarRowHeight }
    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard items.indices.contains(row) else { return nil }
        switch items[row] {
        case .header(let title):
            // A container keeps the inset: the table sizes a cell view to the full row.
            let cell = NSView()
            let label = NSTextField(labelWithString: title)
            label.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
            performWithTheme { label.textColor = Palette.textSecondary }
            label.lineBreakMode = .byTruncatingTail
            label.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: Metrics.space3),
                label.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -Metrics.space2),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            cell.setAccessibilityLabel(title)
            return cell
        case .message(let message):
            let label = NSTextField(wrappingLabelWithString: message)
            label.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
            performWithTheme { label.textColor = Palette.textSecondary }
            label.frame = NSRect(x: Metrics.space3, y: 0, width: max(0, table.bounds.width - Metrics.space4), height: Metrics.sidebarRowHeight)
            label.setAccessibilityLabel(message)
            return label
        case .chat(let row):
            let identifier = NSUserInterfaceItemIdentifier("chat-row")
            let view = (tableView.makeView(withIdentifier: identifier, owner: self) as? SidebarChatRowView) ?? SidebarChatRowView()
            view.identifier = identifier
            view.configure(row, design: design, now: now())
            view.onPress = { [weak self] in self?.onOpen?(row.id) }
            view.onContextMenu = { [weak self] event, view in self?.showRowMenu(row.id, event: event, in: view) }
            view.setAccessibilityLabel(row.title)
            return view
        }
    }
}

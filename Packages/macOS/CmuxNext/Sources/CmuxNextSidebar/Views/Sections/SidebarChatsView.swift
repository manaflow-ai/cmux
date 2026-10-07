public import AppKit
import CmuxNextDesign
import CmuxNextIcons

/// The virtualized Chats section: search, grouping and minimal chat rows.
public final class SidebarChatsView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    public nonisolated static var contribution: String { SidebarLayoutDocument.recentsContribution }
    public static var title: String { String(localized: "sidebar.chats.title", defaultValue: "Chats", bundle: .module) }
    public static var searchPlaceholder: String { String(localized: "sidebar.chats.search", defaultValue: "Search chats", bundle: .module) }
    public static var groupLabel: String { String(localized: "sidebar.chats.group", defaultValue: "Group by", bundle: .module) }
    public static var harnessGroup: String { String(localized: "sidebar.chats.group.harness", defaultValue: "Harness", bundle: .module) }
    public static var folderGroup: String { String(localized: "sidebar.chats.group.folder", defaultValue: "Folder", bundle: .module) }
    public static var accountGroup: String { String(localized: "sidebar.chats.group.account", defaultValue: "Account", bundle: .module) }
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
        public init(id: String, title: String, harness: String, brand: String?, folder: String? = nil, account: String? = nil) {
            self.id = id; self.title = title; self.harness = harness; self.brand = brand; self.folder = folder; self.account = account
        }
    }

    private enum Item {
        case header(String)
        case chat(Row)
        case message(String)
    }

    public var onOpen: ((String) -> Void)?
    public private(set) var rows: [Row] = []
    public private(set) var preferredHeight: CGFloat = Metrics.sidebarRowHeight
    private let search = NSSearchField()
    private let grouping = NSPopUpButton()
    /// The project filter (`SidebarChatsView+ProjectFilter`) and the project it shows, nil for all.
    let filterButton = SidebarIconButton(symbol: "line.3.horizontal.decrease", label: SidebarChatsView.filterTitle)
    var selectedProject: String?
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private var items: [Item] = []
    private var selectedGrouping: SidebarChatsGrouping = .harness
    private let defaults: UserDefaults
    private let preferenceKey = "sidebar.chats.grouping"
    private var lastEnabled = true
    private var lastReady = true

    public init(frame: NSRect = .zero, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        super.init(frame: frame)
        selectedGrouping = SidebarChatsGrouping(rawValue: defaults.string(forKey: preferenceKey) ?? "") ?? .harness
        configure()
    }

    required init?(coder: NSCoder) {
        defaults = .standard
        super.init(coder: coder)
        configure()
    }

    public override var isFlipped: Bool { true }

    private func configure() {
        search.placeholderString = Self.searchPlaceholder
        search.controlSize = .small
        search.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        search.target = self
        search.action = #selector(searchChanged)
        onSearchChanged = { [weak self] in
            guard let self else { return }
            self.refilter()
        }
        search.setAccessibilityLabel(Self.searchPlaceholder)
        grouping.controlSize = .small
        grouping.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        grouping.isBordered = false
        grouping.addItems(withTitles: [Self.harnessGroup, Self.folderGroup, Self.accountGroup])
        grouping.selectItem(at: SidebarChatsGrouping.allCases.firstIndex(of: selectedGrouping) ?? 0)
        grouping.target = self
        grouping.action = #selector(groupingChanged)
        grouping.toolTip = Self.groupLabel
        grouping.setAccessibilityLabel(Self.groupLabel)
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
        addSubview(search)
        addSubview(filterButton)
        addSubview(grouping)
        addSubview(scroll)
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
                let label: (Row) -> String? = switch selectedGrouping {
                case .harness: { Self.harnessName($0.harness) }
                case .folder: { $0.folder.map { ($0 as NSString).lastPathComponent } }
                case .account: { $0.account }
                }
                items = Self.grouped(visible, label: { label($0) ?? Self.emptyGroup })
            }
        }
        table.reloadData()
        let shown = min(max(items.count, 1), Self.maxVisibleRows)
        preferredHeight = Metrics.sidebarRowHeight * CGFloat(1 + shown)
        needsLayout = true
    }

    /// Applies the search, grouping or project filter again to the same rows.
    func refilter() { update(rows, enabled: lastEnabled, ready: lastReady) }

    /// The chats the list shows, in order.
    var shownChatIDs: [String] {
        items.compactMap { if case .chat(let row) = $0 { row.id } else { nil } }
    }

    /// The most chat rows the section shows before it scrolls inside, so the
    /// bottom band keeps room for the footer.
    static let maxVisibleRows = 6

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
    @objc private func groupingChanged() {
        let index = grouping.indexOfSelectedItem
        selectedGrouping = SidebarChatsGrouping.allCases.indices.contains(index) ? SidebarChatsGrouping.allCases[index] : .harness
        defaults.set(selectedGrouping.rawValue, forKey: preferenceKey)
        onSearchChanged?()
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
        let groupWidth: CGFloat = 76
        let filterWidth = filterButton.isHidden ? 0 : controlHeight + Metrics.space1
        let searchWidth = max(0, bounds.width - Metrics.space3 - groupWidth - Metrics.space2 - filterWidth)
        search.frame = NSRect(x: Metrics.space3, y: y, width: searchWidth, height: controlHeight)
        filterButton.frame = NSRect(x: search.frame.maxX + Metrics.space1, y: y, width: controlHeight, height: controlHeight)
        grouping.frame = NSRect(x: max(0, bounds.width - groupWidth - Metrics.space1), y: y, width: groupWidth, height: controlHeight)
        scroll.frame = NSRect(x: 0, y: top, width: bounds.width, height: max(0, bounds.height - top))
    }

    public func numberOfRows(in tableView: NSTableView) -> Int { items.count }
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
            let view = (tableView.makeView(withIdentifier: identifier, owner: self) as? SidebarItemRowView) ?? SidebarItemRowView()
            view.identifier = identifier
            view.configure(SidebarItemInfo(title: row.title, symbol: "bubble.left", icon: .agentChat, brand: row.brand), style: .builtIn)
            view.onPress = { [weak self] in self?.onOpen?(row.id) }
            view.setAccessibilityLabel(row.title)
            return view
        }
    }
}

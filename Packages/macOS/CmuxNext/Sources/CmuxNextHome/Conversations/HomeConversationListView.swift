public import AppKit
public import CmuxHomeCore
import CmuxNextDesign

/// The Home page's left column: the merged inbox in sections
/// (`HomeConversationList`), with a "+" menu for New Message, New Chief and
/// Invite. Choosing a row (click, arrow keys) calls `onSelect`; the host
/// shows that conversation in the transcript column. The view reads only
/// `InboxRow`s from `HomeStore` and owns no data.
public final class HomeConversationListView: NSView {
    public var onSelect: (ConversationID) -> Void = { _ in }
    public var onNewMessage: () -> Void = {}
    public var onNewChief: () -> Void = {}
    public var onInvite: () -> Void = {}
    /// The row's right-click menu (Archive Chief), or nil for none.
    public var contextMenu: (InboxRow) -> NSMenu? = { _ in nil }

    public private(set) var lines: [HomeConversationLine] = []
    public private(set) var selection: ConversationID?
    private var me: ParticipantID?

    let titleLabel = NSTextField(labelWithString: HomeConversationStrings.listTitle)
    let addButton = NSButton()
    let emptyLabel = NSTextField(wrappingLabelWithString: HomeConversationStrings.empty)
    let table = HomeConversationTableView()
    let scroll = NSScrollView()
    private let menuDelegate = HomeConversationMenuDelegate()

    public override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityIdentifier("cmux.home.conversations")
        titleLabel.setAccessibilityRole(.staticText)
        addSubview(titleLabel)
        addButton.bezelStyle = .accessoryBarAction
        addButton.isBordered = false
        addButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: HomeConversationStrings.newMenu)
        addButton.target = self
        addButton.action = #selector(showAddMenu(_:))
        addButton.setAccessibilityLabel(HomeConversationStrings.newMenu)
        addButton.setAccessibilityIdentifier("cmux.home.conversations.new")
        addSubview(addButton)
        emptyLabel.alignment = .center
        emptyLabel.isHidden = true
        addSubview(emptyLabel)
        configureTable()
        applyColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private func configureTable() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("conversation"))
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.backgroundColor = .clear
        table.intercellSpacing = .zero
        table.selectionHighlightStyle = .regular
        table.allowsEmptySelection = true
        table.focusRingType = .none
        table.dataSource = self
        table.delegate = self
        table.setAccessibilityLabel(HomeConversationStrings.listTitle)
        table.setAccessibilityIdentifier("cmux.home.conversations.table")
        menuDelegate.list = self
        let menu = NSMenu()
        menu.delegate = menuDelegate
        table.menu = menu
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        addSubview(scroll)
    }

    /// Shows `rows` (inbox order) and keeps the selection when its row stays.
    public func update(rows: [InboxRow], me: ParticipantID?) {
        self.me = me
        let next = rows.homeLines
        guard next != lines else { return }
        lines = next
        table.reloadData()
        emptyLabel.isHidden = !rows.isEmpty
        restoreSelection()
    }

    /// Selects `id` without calling `onSelect` (the host already shows it).
    public func select(_ id: ConversationID?) {
        selection = id
        restoreSelection()
    }

    private func restoreSelection() {
        let index = selection.flatMap { id in lines.firstIndex { $0.conversation == id } }
        programmatic = true
        defer { programmatic = false }
        if let index { table.selectRowIndexes([index], byExtendingSelection: false) } else { table.deselectAll(nil) }
    }

    private var programmatic = false

    /// The row at `index` was chosen by the user.
    func choose(_ index: Int) {
        guard lines.indices.contains(index), let id = lines[index].conversation else { return }
        selection = id
        if !programmatic { onSelect(id) }
    }

    func row(at index: Int) -> InboxRow? {
        guard lines.indices.contains(index), case .row(let row) = lines[index] else { return nil }
        return row
    }

    @objc func showAddMenu(_ sender: NSButton) {
        addMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY + Metrics.space1), in: sender)
    }

    /// New Message, New Chief and Invite, in that order.
    func addMenu() -> NSMenu {
        let menu = NSMenu()
        for (title, action) in [(HomeConversationStrings.newMessage, #selector(newMessage)),
                                (HomeConversationStrings.newChief, #selector(newChief)),
                                (HomeConversationStrings.invite, #selector(invite))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        return menu
    }

    @objc func newMessage() { onNewMessage() }
    @objc func newChief() { onNewChief() }
    @objc func invite() { onInvite() }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func applyColors() {
        performWithTheme {
            titleLabel.font = Typography.header
            titleLabel.textColor = Palette.textPrimary
            addButton.contentTintColor = Palette.textSecondary
            emptyLabel.font = Typography.caption
            emptyLabel.textColor = Palette.textTertiary
        }
    }

    public override var isFlipped: Bool { true }

    public override func layout() {
        super.layout()
        let inset = Metrics.space3
        let header = Metrics.sidebarHeaderHeight + Metrics.space2
        let button = Metrics.sidebarHeaderHeight
        addButton.frame = CGRect(x: bounds.width - inset - button, y: (header - button) / 2, width: button, height: button)
        let titleHeight = ceil(titleLabel.intrinsicContentSize.height)
        titleLabel.frame = CGRect(x: inset, y: (header - titleHeight) / 2, width: max(0, addButton.frame.minX - inset), height: titleHeight)
        scroll.frame = CGRect(x: 0, y: header, width: bounds.width, height: max(0, bounds.height - header))
        table.tableColumns.first?.width = scroll.contentSize.width
        emptyLabel.preferredMaxLayoutWidth = max(0, bounds.width - 2 * inset)
        let emptyHeight = ceil(emptyLabel.intrinsicContentSize.height)
        emptyLabel.frame = CGRect(x: inset, y: header + Metrics.space6, width: max(0, bounds.width - 2 * inset), height: emptyHeight)
    }
}

extension HomeConversationListView: NSTableViewDataSource, NSTableViewDelegate {
    public func numberOfRows(in tableView: NSTableView) -> Int { lines.count }

    public func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .header = lines[row] { true } else { false }
    }

    public func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if case .header = lines[row] { HomeConversationHeaderView.height } else { HomeConversationCellView.height }
    }

    public func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        lines[row].conversation != nil
    }

    public func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        HomeConversationTableRowView()
    }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch lines[row] {
        case .header(let kind):
            let view = tableView.makeView(withIdentifier: HomeConversationHeaderView.identifier, owner: nil) as? HomeConversationHeaderView
                ?? HomeConversationHeaderView()
            view.show(kind)
            return view
        case .row(let inbox):
            let view = tableView.makeView(withIdentifier: HomeConversationCellView.identifier, owner: nil) as? HomeConversationCellView
                ?? HomeConversationCellView()
            view.show(inbox, me: me)
            return view
        }
    }

    public func tableViewSelectionDidChange(_ notification: Notification) {
        guard table.selectedRow >= 0 else { return }
        choose(table.selectedRow)
    }
}

/// Arrow keys move between conversations and skip the section headers.
final class HomeConversationTableView: NSTableView {
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 125: step(1)
        case 126: step(-1)
        default: super.keyDown(with: event)
        }
    }

    func step(_ offset: Int) {
        guard let delegate = delegate as? HomeConversationListView else { return }
        let start = selectedRow < 0 ? (offset > 0 ? -1 : numberOfRows) : selectedRow
        // The next conversation row in the direction of `offset` (headers skipped).
        let candidates = offset > 0 ? Array(stride(from: start + 1, to: numberOfRows, by: 1))
                                    : Array(stride(from: start - 1, through: 0, by: -1))
        guard let index = candidates.first(where: { delegate.lines[$0].conversation != nil }) else { return }
        selectRowIndexes([index], byExtendingSelection: false)
        scrollRowToVisible(index)
    }
}

/// Builds the right-click menu of the clicked row from the host's items.
final class HomeConversationMenuDelegate: NSObject, NSMenuDelegate {
    weak var list: HomeConversationListView?

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let list, let row = list.row(at: list.table.clickedRow), let items = list.contextMenu(row) else { return }
        for item in items.items {
            items.removeItem(item)
            menu.addItem(item)
        }
    }
}

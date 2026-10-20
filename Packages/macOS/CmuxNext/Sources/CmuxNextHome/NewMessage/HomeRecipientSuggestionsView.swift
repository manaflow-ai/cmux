public import AppKit
import CmuxNextDesign

/// The people under New Message's To: field as the person types (Messages'
/// suggestion list): a name and where it comes from (Team, Contact, Chief,
/// Email, Phone). A click chooses one; the field moves the highlight with
/// Up and Down and chooses it with Return.
public final class HomeRecipientSuggestionsView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    /// A suggestion was clicked.
    public var onChoose: (HomeRecipient) -> Void = { _ in }
    /// The rows shown, best first.
    public private(set) var items: [HomeRecipient] = []
    /// The highlighted row (Return chooses it); nil when nothing is shown.
    public private(set) var highlighted: Int?
    /// A line shown instead of rows (the + button with nobody to pick).
    private(set) var emptyText: String?

    let table = NSTableView()
    let scroll = NSScrollView()
    let emptyLabel = ThemedLabel(wrappingLabelWithString: "")
    static let rowHeight: CGFloat = 36
    static let maxRows = 6

    public override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
        layer?.borderWidth = 0.5
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("recipient"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = Self.rowHeight
        table.intercellSpacing = .zero
        table.backgroundColor = .clear
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clicked)
        table.refusesFirstResponder = true
        table.setAccessibilityIdentifier("cmux.home.newMessage.suggestions")
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        SystemScrollers.follow(scroll)
        addSubview(scroll)
        emptyLabel.font = Typography.caption
        emptyLabel.ink = .secondary
        emptyLabel.isHidden = true
        addSubview(emptyLabel)
        isHidden = true
        applyColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// Shows `items` with the first highlighted, or `empty` when there are
    /// none and a line should say why; hidden when both are empty.
    public func show(_ items: [HomeRecipient], empty: String? = nil) {
        self.items = items
        emptyText = items.isEmpty ? empty : nil
        highlighted = items.isEmpty ? nil : 0
        emptyLabel.stringValue = emptyText ?? ""
        emptyLabel.isHidden = emptyText == nil
        scroll.isHidden = items.isEmpty
        isHidden = items.isEmpty && emptyText == nil
        table.reloadData()
        syncHighlight()
    }

    /// The height the view wants for its rows (at most ``maxRows``).
    public var preferredHeight: CGFloat {
        if emptyText != nil { return 44 }
        return CGFloat(min(items.count, Self.maxRows)) * Self.rowHeight + 8
    }

    /// Moves the highlight by `offset`, stopping at the ends.
    public func move(_ offset: Int) {
        guard !items.isEmpty else { return }
        highlighted = min(max((highlighted ?? -1) + offset, 0), items.count - 1)
        syncHighlight()
    }

    /// The highlighted suggestion (Return chooses it).
    public var highlightedItem: HomeRecipient? { highlighted.flatMap { items.indices.contains($0) ? items[$0] : nil } }

    private func syncHighlight() {
        guard let highlighted else { return table.deselectAll(nil) }
        table.selectRowIndexes(IndexSet(integer: highlighted), byExtendingSelection: false)
        table.scrollRowToVisible(highlighted)
    }

    @objc func clicked() {
        let row = table.clickedRow
        guard items.indices.contains(row) else { return }
        onChoose(items[row])
    }

    public override func layout() {
        super.layout()
        scroll.frame = bounds.insetBy(dx: 0, dy: 4)
        table.tableColumns.first?.width = scroll.contentSize.width
        emptyLabel.frame = bounds.insetBy(dx: Metrics.space4, dy: 12)
    }

    func applyColors() {
        layer?.backgroundColor = performWithTheme { Palette.popupSurface.cgColor }
        layer?.borderColor = performWithTheme { Palette.separator.cgColor }
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    // MARK: Table

    public func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    public func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { ThemedTableRowView() }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = items[row]
        let cell = NSTableCellView()
        let name = ThemedLabel(labelWithString: item.label)
        name.font = Typography.body
        name.lineBreakMode = .byTruncatingTail
        let detail = ThemedLabel(labelWithString: Self.detail(item))
        detail.font = Typography.caption
        detail.ink = .secondary
        detail.alignment = .right
        for label in [name, detail] {
            label.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(label)
        }
        detail.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            name.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: Metrics.space4),
            name.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            detail.leadingAnchor.constraint(greaterThanOrEqualTo: name.trailingAnchor, constant: Metrics.space3),
            detail.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -Metrics.space4),
            detail.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        cell.setAccessibilityLabel("\(item.label), \(detail.stringValue)")
        return cell
    }

    public func tableViewSelectionDidChange(_ notification: Notification) {
        let row = table.selectedRow
        if row >= 0 { highlighted = row }
    }

    /// Where a suggestion comes from, as its row's right-hand label.
    static func detail(_ item: HomeRecipient) -> String {
        switch item {
        case .address(let address): address.isEmail ? HomeConversationStrings.addressEmail : HomeConversationStrings.addressPhone
        case .contact(let contact):
            switch contact.source {
            case .team: HomeConversationStrings.sourceTeam
            case .connection: HomeConversationStrings.sourceConnection
            case .agent: HomeConversationStrings.sourceAgent
            }
        }
    }
}

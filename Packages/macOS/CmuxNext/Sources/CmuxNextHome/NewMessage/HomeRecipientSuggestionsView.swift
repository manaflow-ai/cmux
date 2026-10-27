public import AppKit
import CmuxNextCompat
import CmuxNextDesign

/// The people under New Message's To: field (Messages' suggestion list):
/// each row an avatar, the full name and under it what the recipient is
/// (Team, Contact, Email, Phone; a Chief with where it runs, "Chief · Main ·
/// Cloud", so two Chiefs with one name tell apart). Before anything is typed
/// it lists the Chiefs. A click chooses one; the field moves the highlight
/// with Up and Down and chooses it with Return.
public final class HomeRecipientSuggestionsView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    /// A suggestion was clicked.
    public var onChoose: (HomeRecipient) -> Void = { _ in }
    /// The avatar and the line under the name the page knows for a recipient.
    public var look: (HomeRecipient) -> HomeRecipientLook = { _ in HomeRecipientLook() }
    /// The rows shown, best first.
    public private(set) var items: [HomeRecipient] = []
    /// The highlighted row (Return chooses it); nil when nothing is shown or nothing is highlighted yet.
    public private(set) var highlighted: Int?
    /// A line shown instead of rows (the + button with nobody to pick).
    private(set) var emptyText: String?

    let table = NSTableView()
    let scroll = NSScrollView()
    let emptyLabel = ThemedLabel(wrappingLabelWithString: "")
    /// The list floats over the page: the shared overlay glass, never the solid popup surface
    /// (Leo 2026-10-21: "STOP DOING SOLID. WE HAVE GLASS, SO JUST USE GLASS.").
    let glass = Glass.makeOverlayPanel(cornerRadius: 10, interactive: false)
    static let rowHeight: CGFloat = 44
    static let avatarSize: CGFloat = 28
    static let maxRows = 6

    public override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
        glass.translatesAutoresizingMaskIntoConstraints = true
        glass.autoresizingMask = [.width, .height]
        glass.frame = bounds
        addSubview(glass)
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
        HomeRecipientAvatarView.forgetPictures()
        applyColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// Shows `items` with the first highlighted (with `highlightFirst` off,
    /// none until Down), or `empty` when there are none and a line should
    /// say why; hidden when both are empty.
    public func show(_ items: [HomeRecipient], empty: String? = nil, highlightFirst: Bool = true) {
        self.items = items
        emptyText = items.isEmpty ? empty : nil
        highlighted = items.isEmpty || !highlightFirst ? nil : 0
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
        guard let row = table.clickedRowIfValid, items.indices.contains(row) else { return }
        onChoose(items[row])
    }

    public override func layout() {
        super.layout()
        scroll.frame = bounds.insetBy(dx: 0, dy: 4)
        table.tableColumns.first?.width = scroll.contentSize.width
        emptyLabel.frame = bounds.insetBy(dx: Metrics.space4, dy: 12)
    }

    func applyColors() {
        glass.applyTheme()
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
        let shown = self.look(item)
        let cell = NSTableCellView()
        let avatar = HomeRecipientAvatarView()
        avatar.show(shown.avatar, name: item.label)
        let name = ThemedLabel(labelWithString: item.label)
        name.font = Typography.body
        name.lineBreakMode = .byTruncatingTail
        let detail = ThemedLabel(labelWithString: ([Self.detail(item)] + [shown.tag].compactMap { $0 }).joined(separator: " \u{00B7} "))
        detail.font = Typography.caption
        detail.ink = .secondary
        detail.lineBreakMode = .byTruncatingTail
        for view in [avatar, name, detail] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(view)
        }
        NSLayoutConstraint.activate([
            avatar.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: Metrics.space4),
            avatar.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            avatar.widthAnchor.constraint(equalToConstant: Self.avatarSize),
            avatar.heightAnchor.constraint(equalToConstant: Self.avatarSize),
            name.leadingAnchor.constraint(equalTo: avatar.trailingAnchor, constant: Metrics.space3),
            name.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -Metrics.space4),
            name.bottomAnchor.constraint(equalTo: cell.centerYAnchor, constant: 1),
            detail.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            detail.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -Metrics.space4),
            detail.topAnchor.constraint(equalTo: cell.centerYAnchor, constant: 1),
        ])
        cell.setAccessibilityLabel("\(item.label), \(detail.stringValue)")
        return cell
    }

    public func tableViewSelectionDidChange(_ notification: Notification) {
        let row = table.selectedRow
        if row >= 0 { highlighted = row }
    }

    /// Where a suggestion comes from, as the line under its name (a Chief's tag follows it).
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

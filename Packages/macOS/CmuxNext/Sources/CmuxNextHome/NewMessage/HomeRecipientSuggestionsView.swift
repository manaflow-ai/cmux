public import AppKit
import CmuxNextCompat
import CmuxNextDesign

/// The people under New Message's To: field (Messages' suggestion list):
/// each row an avatar, the full name and under it what the recipient is
/// (Team, Contact, Email, Phone; a Chief with where it runs, "Chief · Main ·
/// Cloud"; rows that would still read the same add when each was last active,
/// else a number, so two Chiefs named alike tell apart). Before anything is
/// typed it lists the Chiefs and the team in sections, with New Chief after the
/// Chiefs (the user, 2026-10-27). A click chooses a row; the field moves the
/// highlight with Up and Down (headers are skipped) and chooses it with Return.
public final class HomeRecipientSuggestionsView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    /// A suggestion was clicked.
    public var onChoose: (HomeRecipient) -> Void = { _ in }
    /// The New Chief row was picked.
    public var onNewChief: () -> Void = {}
    /// The Invite row was picked.
    public var onInvite: () -> Void = {}
    /// The avatar and the line under the name the page knows for a recipient.
    public var look: (HomeRecipient) -> HomeRecipientLook = { _ in HomeRecipientLook() }
    /// The rows shown, headers and actions included.
    public private(set) var rows: [HomeRecipientSuggestion] = []
    /// The recipients shown, best first.
    public var items: [HomeRecipient] {
        rows.compactMap { if case .recipient(let recipient) = $0 { recipient } else { nil } }
    }
    /// The highlighted row's index in ``rows`` (Return chooses it); nil when nothing is shown or highlighted yet.
    public private(set) var highlighted: Int?
    /// A line shown instead of rows (the + button with nobody to pick).
    private(set) var emptyText: String?
    /// Each recipient row's look and line under its name, by row (computed once per ``show(rows:empty:highlightFirst:)``).
    private var lines: [Int: (look: HomeRecipientLook, detail: String)] = [:]

    let table = NSTableView()
    let scroll = NSScrollView()
    let emptyLabel = ThemedLabel(wrappingLabelWithString: "")
    /// The list floats over the page: the shared overlay glass, never the solid popup surface
    /// (Leo 2026-10-21: "STOP DOING SOLID. WE HAVE GLASS, SO JUST USE GLASS.").
    let glass = Glass.makeOverlayPanel(cornerRadius: 10, interactive: false)
    static let rowHeight: CGFloat = 44
    static let headerHeight: CGFloat = 26
    static let avatarSize: CGFloat = 28
    /// The list grows to this many rows' height, then scrolls (the page also caps it at the window).
    static let maxRows = 9

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
        show(rows: items.map(HomeRecipientSuggestion.recipient), empty: empty, highlightFirst: highlightFirst)
    }

    /// Shows `rows` (sections, recipients and actions) with the first pickable one highlighted (with
    /// `highlightFirst` off, none until Down), or `empty` when there are none; hidden when both are empty.
    public func show(rows: [HomeRecipientSuggestion], empty: String? = nil, highlightFirst: Bool = true) {
        self.rows = rows
        lines = Self.lines(for: rows, look: look)
        emptyText = rows.isEmpty ? empty : nil
        highlighted = highlightFirst ? rows.firstIndex(where: \.isSelectable) : nil
        emptyLabel.stringValue = emptyText ?? ""
        emptyLabel.isHidden = emptyText == nil
        scroll.isHidden = rows.isEmpty
        isHidden = rows.isEmpty && emptyText == nil
        table.reloadData()
        syncHighlight()
    }

    /// The height the view wants for its rows (at most ``maxRows`` rows' height).
    public var preferredHeight: CGFloat {
        if emptyText != nil { return 44 }
        let all = rows.reduce(CGFloat(0)) { $0 + Self.height(of: $1) }
        return min(all, CGFloat(Self.maxRows) * Self.rowHeight) + 8
    }

    /// Moves the highlight by `offset` pickable rows (headers are skipped), stopping at the ends.
    public func move(_ offset: Int) {
        let pickable = rows.indices.filter { rows[$0].isSelectable }
        guard !pickable.isEmpty else { return }
        let at = highlighted.flatMap { pickable.firstIndex(of: $0) } ?? -1
        highlighted = pickable[min(max(at + offset, 0), pickable.count - 1)]
        syncHighlight()
    }

    /// The highlighted row (Return chooses it).
    public var highlightedRow: HomeRecipientSuggestion? { highlighted.flatMap { rows.indices.contains($0) ? rows[$0] : nil } }

    /// The highlighted recipient; nil when nothing or an action row is highlighted.
    public var highlightedItem: HomeRecipient? {
        if case .recipient(let recipient) = highlightedRow { return recipient }
        return nil
    }

    /// Runs `row`: a recipient is chosen, an action runs; a header does nothing.
    public func activate(_ row: HomeRecipientSuggestion) {
        switch row {
        case .recipient(let recipient): onChoose(recipient)
        case .newChief: onNewChief()
        case .invite: onInvite()
        case .header: break
        }
    }

    private func syncHighlight() {
        guard let highlighted else { return table.deselectAll(nil) }
        table.selectRowIndexes(IndexSet(integer: highlighted), byExtendingSelection: false)
        table.scrollRowToVisible(highlighted)
    }

    @objc func clicked() {
        guard let row = table.clickedRowIfValid, rows.indices.contains(row) else { return }
        activate(rows[row])
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

    public func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    public func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        rows.indices.contains(row) ? Self.height(of: rows[row]) : Self.rowHeight
    }

    public func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        rows.indices.contains(row) && rows[row].isSelectable
    }

    public func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { ThemedTableRowView() }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .header(let title): return Self.headerCell(title)
        case .newChief:
            return entryCell(name: HomeConversationStrings.newChief, detail: nil, symbol: "plus", avatar: nil, label: HomeConversationStrings.newChief)
        case .invite:
            return entryCell(name: HomeConversationStrings.invite, detail: nil, symbol: "envelope", avatar: nil, label: HomeConversationStrings.invite)
        case .recipient(let item):
            let line = lines[row] ?? (look(item), Self.detail(item))
            return entryCell(name: item.label, detail: line.detail, symbol: nil, avatar: line.look.avatar,
                             label: "\(item.label), \(line.detail)")
        }
    }

    /// A section title row: small secondary text, not pickable.
    private static func headerCell(_ title: String) -> NSView {
        let cell = NSTableCellView()
        let label = ThemedLabel(labelWithString: title)
        label.font = Typography.caption
        label.ink = .secondary
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: Metrics.space4),
            label.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -Metrics.space4),
            label.bottomAnchor.constraint(equalTo: cell.bottomAnchor, constant: -4),
        ])
        cell.setAccessibilityRole(.staticText)
        cell.setAccessibilityLabel(title)
        return cell
    }

    /// A pickable row: an avatar (or an action's symbol in the avatar's place), the name, and the line under it.
    private func entryCell(name: String, detail: String?, symbol: String?, avatar: HomeChiefAvatar?, label: String) -> NSView {
        let cell = NSTableCellView()
        let leading: NSView
        if let symbol {
            let image = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
            image.contentTintColor = .secondaryLabelColor
            image.symbolConfiguration = .init(pointSize: TypeScale.body, weight: TypeScale.regular)
            leading = image
        } else {
            let disc = HomeRecipientAvatarView()
            disc.show(avatar, name: name)
            leading = disc
        }
        let title = ThemedLabel(labelWithString: name)
        title.font = Typography.body
        title.lineBreakMode = .byTruncatingTail
        var views: [NSView] = [leading, title]
        var constraints = [
            leading.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: Metrics.space4),
            leading.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            leading.widthAnchor.constraint(equalToConstant: Self.avatarSize),
            leading.heightAnchor.constraint(equalToConstant: Self.avatarSize),
            title.leadingAnchor.constraint(equalTo: leading.trailingAnchor, constant: Metrics.space3),
            title.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -Metrics.space4),
        ]
        if let detail {
            let line = ThemedLabel(labelWithString: detail)
            line.font = Typography.caption
            line.ink = .secondary
            line.lineBreakMode = .byTruncatingTail
            views.append(line)
            constraints += [
                title.bottomAnchor.constraint(equalTo: cell.centerYAnchor, constant: 1),
                line.leadingAnchor.constraint(equalTo: title.leadingAnchor),
                line.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -Metrics.space4),
                line.topAnchor.constraint(equalTo: cell.centerYAnchor, constant: 1),
            ]
        } else {
            constraints.append(title.centerYAnchor.constraint(equalTo: cell.centerYAnchor))
        }
        for view in views {
            view.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(view)
        }
        NSLayoutConstraint.activate(constraints)
        cell.setAccessibilityLabel(label)
        return cell
    }

    public func tableViewSelectionDidChange(_ notification: Notification) {
        let row = table.selectedRow
        if row >= 0 { highlighted = row }
    }

    private static func height(of row: HomeRecipientSuggestion) -> CGFloat {
        if case .header = row { return headerHeight }
        return rowHeight
    }

    /// Each recipient row's look and the line under its name. A line that, with its name, reads the
    /// same as another row's gets when the recipient was last active; still alike, a number ("2").
    private static func lines(for rows: [HomeRecipientSuggestion],
                              look: (HomeRecipient) -> HomeRecipientLook) -> [Int: (look: HomeRecipientLook, detail: String)] {
        var result: [Int: (look: HomeRecipientLook, detail: String)] = [:]
        for (index, row) in rows.enumerated() {
            guard case .recipient(let item) = row else { continue }
            let shown = look(item)
            result[index] = (shown, ([detail(item)] + [shown.tag].compactMap { $0 }).joined(separator: " \u{00B7} "))
        }
        func collisions() -> [String: [Int]] {
            Dictionary(grouping: result.keys.sorted(), by: { index -> String in
                guard case .recipient(let item) = rows[index] else { return "" }
                return "\(item.label)\u{0}\(result[index]?.detail ?? "")"
            }).filter { $0.value.count > 1 }
        }
        for indices in collisions().values {
            for index in indices {
                guard let line = result[index], let activity = line.look.activity else { continue }
                result[index]?.detail = line.detail + " \u{00B7} " + activity
            }
        }
        for indices in collisions().values {
            for (number, index) in indices.enumerated() where number > 0 {
                result[index]?.detail += " \u{00B7} \(number + 1)"
            }
        }
        return result
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

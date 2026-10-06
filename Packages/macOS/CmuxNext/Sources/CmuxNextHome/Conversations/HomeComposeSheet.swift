public import AppKit
public import CmuxHomeCore
import CmuxNextDesign

/// New Message: pick people from the user's contacts (team members and
/// connected people) or type an email address, optionally name a group,
/// and start. One person opens the DM (`dm.open`); several make a group
/// (`conversation.create`); an address gets an invite. When the owner says
/// a person cannot be reached, the sheet offers Invite by Email.
public final class HomeComposeSheet: HomeSheetController, NSSearchFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    public var onStart: ([HomeRecipient], String) async -> HomeComposeOutcome = { _, _ in .offline }
    /// Invite by Email after a refusal; the text is a prefill (may be empty).
    public var onInviteInstead: (String) -> Void = { _ in }

    let search = NSSearchField()
    let table = NSTableView()
    let scroll = NSScrollView()
    let toLabel = NSTextField(labelWithString: "")
    /// Says how to reach someone when the user has no teammates or contacts yet.
    let emptyLabel = NSTextField(wrappingLabelWithString: HomeConversationStrings.composeNoContacts)
    let groupName = HomeSheetController.field(placeholder: HomeConversationStrings.composeGroupName, identifier: "cmux.home.compose.group")
    let inviteButton = NSButton(title: HomeConversationStrings.inviteByEmail, target: nil, action: nil)
    private let contacts: [HomeContact]
    private(set) var chosen: [HomeRecipient] = []
    /// The rows under the search field: a typed address first, then contacts.
    private(set) var shown: [HomeRecipient] = []

    public init(contacts: [HomeContact]) {
        self.contacts = contacts
        super.init(title: HomeConversationStrings.composeTitle, primary: HomeConversationStrings.composeStart)
    }

    override func addContent(to stack: NSStackView) {
        search.placeholderString = HomeConversationStrings.composeSearch
        search.setAccessibilityLabel(HomeConversationStrings.composeSearch)
        search.setAccessibilityIdentifier("cmux.home.compose.search")
        search.delegate = self
        search.translatesAutoresizingMaskIntoConstraints = false
        search.widthAnchor.constraint(equalToConstant: 420 - 2 * Metrics.space6).isActive = true
        stack.addArrangedSubview(search)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("person"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = Metrics.sidebarRowHeight + Metrics.space1
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(toggleClicked)
        table.setAccessibilityLabel(HomeConversationStrings.composeSearch)
        table.setAccessibilityIdentifier("cmux.home.compose.people")
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.widthAnchor.constraint(equalToConstant: 420 - 2 * Metrics.space6).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: 180).isActive = true
        stack.addArrangedSubview(scroll)
        emptyLabel.font = Typography.caption
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.isHidden = true
        emptyLabel.setAccessibilityIdentifier("cmux.home.compose.empty")
        stack.addArrangedSubview(emptyLabel)
        toLabel.font = Typography.body
        toLabel.lineBreakMode = .byTruncatingTail
        toLabel.setAccessibilityIdentifier("cmux.home.compose.to")
        stack.addArrangedSubview(toLabel)
        stack.addArrangedSubview(groupName)
        inviteButton.target = self
        inviteButton.action = #selector(inviteInstead)
        inviteButton.isHidden = true
        stack.addArrangedSubview(inviteButton)
        refilter()
    }

    public override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(search)
    }

    /// Recomputes the rows for the search text.
    func refilter() {
        let query = search.stringValue.trimmingCharacters(in: .whitespaces)
        var rows: [HomeRecipient] = []
        if let address = ContactAddress.parse(query), address.isEmail, !chosen.contains(.address(address)) {
            rows.append(.address(address))
        }
        let matches = query.isEmpty ? contacts : contacts.filter { $0.name.localizedStandardContains(query) }
        rows += matches.map(HomeRecipient.contact)
        shown = rows
        table.reloadData()
        refreshChosen()
    }

    /// Adds or removes the recipient at `index` of `shown`.
    func toggle(_ index: Int) {
        guard shown.indices.contains(index) else { return }
        let recipient = shown[index]
        if let at = chosen.firstIndex(of: recipient) { chosen.remove(at: at) } else { chosen.append(recipient) }
        if case .address = recipient { search.stringValue = "" }
        refilter()
    }

    @objc func toggleClicked() { toggle(table.clickedRow >= 0 ? table.clickedRow : table.selectedRow) }

    private func refreshChosen() {
        toLabel.stringValue = chosen.isEmpty ? "" : HomeConversationStrings.composeTo(chosen.map(\.label).joined(separator: ", "))
        toLabel.isHidden = chosen.isEmpty
        groupName.isHidden = chosen.count < 2
        refreshPrimary()
    }

    override var canSubmit: Bool { !chosen.isEmpty }

    override func submit() {
        inviteButton.isHidden = true
        let recipients = chosen
        let title = groupName.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let start = onStart
        run { await start(recipients, title) }
    }

    override func finish(_ outcome: HomeComposeOutcome) {
        super.finish(outcome)
        if case .notReachable = outcome { inviteButton.isHidden = false }
    }

    @objc func inviteInstead() {
        close(showing: nil)
        onInviteInstead("")
    }

    public func controlTextDidChange(_ notification: Notification) { refilter() }

    /// Return in the search field adds the first row (the typed address or
    /// the best match); with an empty search it starts.
    public func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
        if !search.stringValue.isEmpty, !shown.isEmpty { toggle(0) } else { primary(nil) }
        return true
    }

    public func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let recipient = shown[row]
        let label = NSTextField(labelWithString: "")
        let picked = chosen.contains(recipient)
        switch recipient {
        case .address(let address): label.stringValue = HomeConversationStrings.composeAddAddress(address.description)
        case .contact(let contact):
            let source = contact.source == .team ? HomeConversationStrings.sourceTeam : HomeConversationStrings.sourceConnection
            label.stringValue = "\(contact.name)  ·  \(source)"
        }
        label.font = picked ? Typography.bodyEmphasized : Typography.body
        let cell = NSTableCellView()
        let check = NSImageView(image: NSImage(systemSymbolName: picked ? "checkmark.circle.fill" : "circle",
                                               accessibilityDescription: nil) ?? NSImage())
        check.frame = NSRect(x: Metrics.space2, y: 4, width: 16, height: 16)
        label.frame = NSRect(x: Metrics.space2 + 22, y: 3, width: 320, height: 18)
        cell.addSubview(check)
        cell.addSubview(label)
        cell.textField = label
        cell.setAccessibilityLabel(label.stringValue)
        cell.setAccessibilityValue(picked ? "1" : "0")
        return cell
    }
}

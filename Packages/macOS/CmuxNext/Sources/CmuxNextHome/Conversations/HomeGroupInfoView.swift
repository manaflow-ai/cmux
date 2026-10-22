import AppKit
import CmuxHomeCore
import CmuxNextCompat
import CmuxNextDesign

/// The group info sheet (styled as the Home page's other sheets: the sheet's glass, a
/// title, the content, a status line, then the buttons). A group shows its name (editable),
/// its members with Remove, Add People…, Hide Alerts and Leave Group…; a DM shows the person and
/// Hide Alerts.
///
/// AppKit (plans/cmux-next/no-swiftui-DESIGN.md). The fields keep their editors across updates;
/// the member and contact lists are rebuilt from value snapshots only when their inputs change.
/// A control's action updates the sheet at once; other model changes arrive through observation.
final class HomeGroupInfoView: NSView, NSTextFieldDelegate {
    private let model: HomeGroupInfoModel
    private let colors: HomeGroupInfoColors
    private static let width: CGFloat = 420
    private static var innerWidth: CGFloat { width - 2 * Metrics.space6 }

    private let stack = NSStackView()
    private let title = NSTextField(labelWithString: "")
    private let directTitle = NSTextField(labelWithString: "")
    private let nameField = HomeSheetController.field(placeholder: HomeConversationStrings.infoName, identifier: "cmux.home.groupInfo.name")
    private lazy var nameRow = NSStackView(views: [HomeSheetController.boxed(nameField), renameButton])
    private let renameButton = ThemedBezelButton(title: HomeConversationStrings.infoRename, target: nil, action: nil)
    private let membersHeader = NSTextField(labelWithString: "")
    private let memberList = NSStackView()
    private lazy var memberScroll = Self.scroll(memberList)
    private var memberHeight: NSLayoutConstraint?
    private let addPeopleButton = ThemedBezelButton(title: HomeConversationStrings.infoAddPeople, target: nil, action: nil)
    private let addPanel = NSStackView()
    private let searchField = HomeSheetController.field(placeholder: HomeConversationStrings.infoAddSearch, identifier: "cmux.home.groupInfo.search")
    private let noOneToAdd = NSTextField(labelWithString: HomeConversationStrings.infoNoOneToAdd)
    private let contactList = NSStackView()
    private lazy var contactScroll = Self.scroll(contactList)
    private var contactHeight: NSLayoutConstraint?
    private let addChosenButton = ThemedBezelButton(title: HomeConversationStrings.infoAdd, target: nil, action: nil)
    private let repliesPopup = ThemedPopUpButton(frame: .zero, pullsDown: false)
    private let repliesDetail = NSTextField(wrappingLabelWithString: "")
    private lazy var repliesRow = NSStackView(views: [repliesLine, repliesDetail])
    private lazy var repliesLine = NSStackView(views: [Self.label(HomeConversationStrings.infoChiefReplies, colors.primary), repliesPopup])
    private let alertsSwitch = NSSwitch()
    private lazy var alertsRow = NSStackView(views: [Self.label(HomeConversationStrings.infoHideAlerts, colors.primary), alertsSwitch])
    private let status = NSTextField(wrappingLabelWithString: "")
    private let inviteButton = ThemedBezelButton(title: HomeConversationStrings.inviteByEmail, target: nil, action: nil)
    private let leaveButton = ThemedBezelButton(title: HomeConversationStrings.infoLeave, target: nil, action: nil)
    private let doneButton = ThemedBezelButton(title: HomeConversationStrings.infoDone, target: nil, action: nil)
    private var shownMembers: [HomeGroupMember]?
    private var shownMembersRemovable = false
    private var shownContacts: [HomeContact]?
    private var shownChosen: [ParticipantID] = []
    private var observation: Task<Void, Never>?

    init(model: HomeGroupInfoModel, colors: HomeGroupInfoColors) {
        self.model = model
        self.colors = colors
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 300))
        build()
        refresh()
        observation = Task { [weak self, model] in
            for await _ in ObservationStream({ Snapshot(model) }) {
                self?.refresh()
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // cx-t7hu: not an isolated deinit; its runtime hop traps when released inside an action's task-local scope.
    nonisolated deinit {
        guard Thread.isMainThread else { return } // main-proof: returns off the main thread
        MainActor.assumeIsolated { observation?.cancel() }
    }

    nonisolated override var isFlipped: Bool { true }

    /// What the sheet draws from the model (observation re-runs `refresh` when it changes).
    private struct Snapshot: Equatable, Sendable {
        let info: HomeGroupInfo, addable: [HomeContact], status: String?, offersInvite: Bool
        let isRunning: Bool, isAdding: Bool, chosen: [ParticipantID], search: String, nameDraft: String
        @MainActor init(_ model: HomeGroupInfoModel) {
            info = model.info; addable = model.addable; status = model.status; offersInvite = model.offersInvite
            isRunning = model.isRunning; isAdding = model.isAdding; chosen = model.chosen; search = model.search
            nameDraft = model.nameDraft
        }
    }

    // MARK: Build

    private static func label(_ text: String, _ color: NSColor, font: NSFont = Typography.body) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = font
        label.textColor = color
        return label
    }

    private static func scroll(_ list: NSStackView) -> NSScrollView {
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 0
        list.translatesAutoresizingMaskIntoConstraints = false
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let clip = FlippedClipView()
        clip.drawsBackground = false
        scroll.contentView = clip
        scroll.documentView = list
        NSLayoutConstraint.activate([
            list.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            list.topAnchor.constraint(equalTo: clip.topAnchor),
        ])
        return scroll
    }

    private func wire(_ button: NSControl, _ action: Selector, _ identifier: String) {
        button.target = self
        button.action = action
        button.setAccessibilityIdentifier(identifier)
    }

    private func build() {
        setAccessibilityIdentifier("cmux.home.groupInfo")
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Metrics.space3
        stack.edgeInsets = NSEdgeInsets(top: Metrics.space6, left: Metrics.space6, bottom: Metrics.space6, right: Metrics.space6)
        stack.translatesAutoresizingMaskIntoConstraints = false

        title.font = Typography.title
        title.textColor = colors.primary
        title.setAccessibilityRole(.staticText)
        directTitle.font = Typography.bodyEmphasized
        directTitle.textColor = colors.primary

        nameField.delegate = self
        nameField.target = self
        nameField.action = #selector(renameClicked)
        nameRow.orientation = .horizontal
        nameRow.spacing = Metrics.space3
        wire(renameButton, #selector(renameClicked), "cmux.home.groupInfo.rename")

        membersHeader.font = Typography.caption
        membersHeader.textColor = colors.secondary
        memberHeight = memberScroll.heightAnchor.constraint(equalToConstant: 0)
        memberHeight?.isActive = true

        wire(addPeopleButton, #selector(addPeopleClicked), "cmux.home.groupInfo.addPeople")
        searchField.delegate = self
        noOneToAdd.font = Typography.caption
        noOneToAdd.textColor = colors.secondary
        contactHeight = contactScroll.heightAnchor.constraint(equalToConstant: 0)
        contactHeight?.isActive = true
        let cancelAdd = ThemedBezelButton(title: HomeConversationStrings.cancel, target: nil, action: nil)
        wire(cancelAdd, #selector(cancelAddClicked), "cmux.home.groupInfo.cancelAdd")
        wire(addChosenButton, #selector(addChosenClicked), "cmux.home.groupInfo.addChosen")
        let addButtons = NSStackView(views: [NSView(), cancelAdd, addChosenButton])
        addButtons.orientation = .horizontal
        addPanel.orientation = .vertical
        addPanel.alignment = .leading
        addPanel.spacing = Metrics.space2
        for view in [HomeSheetController.boxed(searchField), noOneToAdd, contactScroll, addButtons] as [NSView] {
            addPanel.addArrangedSubview(view)
        }
        contactScroll.widthAnchor.constraint(equalToConstant: Self.innerWidth).isActive = true
        addButtons.widthAnchor.constraint(equalToConstant: Self.innerWidth).isActive = true

        repliesPopup.font = Typography.body
        for policy in ChiefReplyPolicy.allCases {
            repliesPopup.addItem(withTitle: HomeConversationStrings.chiefReplies(policy))
            repliesPopup.lastItem?.representedObject = policy
        }
        wire(repliesPopup, #selector(repliesChanged), "cmux.home.groupInfo.chiefReplies")
        repliesLine.orientation = .horizontal
        repliesLine.spacing = Metrics.space3
        repliesDetail.font = Typography.caption
        repliesDetail.textColor = colors.secondary
        repliesDetail.preferredMaxLayoutWidth = Self.innerWidth
        repliesRow.orientation = .vertical
        repliesRow.alignment = .leading
        repliesRow.spacing = Metrics.space1

        wire(alertsSwitch, #selector(alertsChanged), "cmux.home.groupInfo.hideAlerts")
        alertsSwitch.setAccessibilityLabel(HomeConversationStrings.infoHideAlerts)
        alertsRow.orientation = .horizontal
        alertsRow.spacing = Metrics.space3

        status.font = Typography.caption
        status.textColor = colors.secondary
        status.preferredMaxLayoutWidth = Self.innerWidth
        status.setAccessibilityIdentifier("cmux.home.groupInfo.status")

        wire(inviteButton, #selector(inviteClicked), "cmux.home.groupInfo.invite")
        wire(leaveButton, #selector(leaveClicked), "cmux.home.groupInfo.leave")
        leaveButton.contentTintColor = colors.danger
        wire(doneButton, #selector(doneClicked), "cmux.home.groupInfo.done")
        doneButton.keyHint = .escape
        let buttons = NSStackView(views: [leaveButton, NSView(), doneButton])
        buttons.orientation = .horizontal
        buttons.spacing = Metrics.space3

        for view in [title, nameRow, directTitle, membersHeader, memberScroll, addPeopleButton, addPanel, repliesRow, alertsRow,
                     status, inviteButton, buttons] as [NSView] {
            stack.addArrangedSubview(view)
        }
        stack.setCustomSpacing(Metrics.space1, after: membersHeader)
        memberScroll.widthAnchor.constraint(equalToConstant: Self.innerWidth).isActive = true
        buttons.widthAnchor.constraint(equalToConstant: Self.innerWidth).isActive = true
        addSubview(stack)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.width),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    // MARK: Refresh

    /// Brings every control to the model's state; lists rebuild only when their inputs changed.
    private func refresh() {
        let info = model.info
        title.stringValue = info.isGroup ? HomeConversationStrings.infoGroupTitle : HomeConversationStrings.infoDirectTitle
        nameRow.isHidden = !info.isGroup
        directTitle.isHidden = info.isGroup
        directTitle.stringValue = info.displayTitle
        if nameField.currentEditor() == nil, nameField.stringValue != model.nameDraft { nameField.stringValue = model.nameDraft }
        renameButton.isEnabled = model.canRename

        membersHeader.stringValue = info.membersHeader
        let removable = info.isGroup && !model.isRunning
        if info.members != shownMembers || removable != shownMembersRemovable {
            shownMembers = info.members
            shownMembersRemovable = removable
            rebuild(memberList, rows: info.members.map(memberRow))
            memberHeight?.constant = min(200, CGFloat(info.members.count) * (Metrics.sidebarRowHeight + Metrics.space1))
        }

        addPeopleButton.isHidden = !info.isGroup || model.isAdding
        addPeopleButton.isEnabled = !model.isRunning
        addPanel.isHidden = !info.isGroup || !model.isAdding
        if model.isAdding {
            if searchField.currentEditor() == nil, searchField.stringValue != model.search { searchField.stringValue = model.search }
            noOneToAdd.isHidden = !model.addable.isEmpty
            contactScroll.isHidden = model.addable.isEmpty
            let shown = model.shownAddable
            let chosen = model.addable.filter { model.isChosen($0.id) }.map(\.id)
            if shown != shownContacts || chosen != shownChosen {
                shownContacts = shown
                shownChosen = chosen
                rebuild(contactList, rows: shown.map { contactRow($0, isChosen: chosen.contains($0.id)) })
                contactHeight?.constant = min(160, CGFloat(shown.count) * Metrics.sidebarRowHeight)
            }
            addChosenButton.isEnabled = !chosen.isEmpty && !model.isRunning
        }

        repliesRow.isHidden = info.chiefReplies == nil
        if let replies = info.chiefReplies {
            repliesPopup.selectItem(at: ChiefReplyPolicy.allCases.firstIndex(of: replies) ?? 0)
            repliesPopup.isEnabled = !model.isRunning
            repliesDetail.stringValue = HomeConversationStrings.chiefRepliesDetail(replies)
        }
        alertsRow.isHidden = !info.canMute
        alertsSwitch.state = info.muted ? .on : .off

        status.isHidden = model.status == nil
        status.stringValue = model.status ?? ""
        inviteButton.isHidden = !model.offersInvite
        leaveButton.isHidden = !info.isGroup
    }

    private func rebuild(_ list: NSStackView, rows: [NSView]) {
        for view in list.arrangedSubviews { view.removeFromSuperview() }
        for row in rows {
            list.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
        }
    }

    /// One member row; Remove only for another member of a group while no action runs.
    private func memberRow(_ member: HomeGroupMember) -> NSView {
        guard model.info.isGroup, !member.isMe, !model.isRunning else {
            return HomeGroupMemberRow(member: member, colors: colors, onRemove: nil)
        }
        let id = member.id
        return HomeGroupMemberRow(member: member, colors: colors, onRemove: { [weak self] in
            self?.model.remove(id)
            self?.refresh()
        })
    }

    /// One contact row of Add People; its click chooses or unchooses the contact.
    private func contactRow(_ contact: HomeContact, isChosen: Bool) -> NSView {
        let id = contact.id
        return HomeGroupContactRow(contact: contact, isChosen: isChosen, colors: colors, onToggle: { [weak self] in
            self?.model.toggle(id)
            self?.refresh()
        })
    }

    // MARK: Actions

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        if field === nameField { model.nameDraft = field.stringValue }
        if field === searchField { model.search = field.stringValue }
        refresh()
    }

    @objc private func renameClicked() { model.rename(); refresh() }
    @objc private func addPeopleClicked() {
        model.isAdding = true
        refresh()
        window?.makeFirstResponder(searchField)
    }
    @objc private func cancelAddClicked() { model.isAdding = false; refresh() }
    @objc private func addChosenClicked() { model.addChosen(); refresh() }
    @objc private func repliesChanged() {
        guard let policy = repliesPopup.selectedItem?.representedObject as? ChiefReplyPolicy else { return }
        model.setChiefReplies(policy)
        refresh()
    }
    @objc private func alertsChanged() { model.setMuted(alertsSwitch.state == .on); refresh() }
    @objc private func inviteClicked() { model.inviteByEmail() }
    @objc private func leaveClicked() { model.leave() }
    @objc private func doneClicked() { model.close() }
}

/// A clip view with a top-left origin, so a short list starts at the top of its scroll view.
private final class FlippedClipView: NSClipView {
    nonisolated override var isFlipped: Bool { true }
}

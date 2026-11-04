package import AppKit
package import CmuxNextDaemonService
import CmuxNextDesign
import Observation

/// Invite People (design chat-multiplayer.md 2, "Invite people"): one chat's invited accounts, an
/// email or @handle field, a Can talk / Can view picker and Invite; each invitee's row has its role
/// and a quiet destructive Remove. A centered dialog over the window, like Share cmux, opened by
/// Invite People… (the tab menu, the palette). AppKit (plans/cmux-next/no-swiftui-DESIGN.md).
///
/// The dialog's card, one fixed size while it shows: the list scrolls in a fixed band and the status
/// line keeps two lines of room, so nothing moves when a row comes or goes. It follows the model
/// through Observation; rows get values and a closure, never the model (cmux#2586). The App's
/// `AgentShareInviteSheetPresenter` puts it over the window and gives it the close icon.
package final class AgentShareInviteCard: NSView, NSTextFieldDelegate {
    static let width: CGFloat = 440
    /// The list's band: four rows, then it scrolls.
    static let listHeight: CGFloat = 4 * AgentShareInviteRowView.height

    package var onClose: (() -> Void)?
    let model: AgentShareInviteSheetModel
    /// The header's x (the App's `actionClose` icon).
    private let closeImage: NSImage
    let field = ThemedTextField(string: "")
    let rolePopup = ThemedPopUpButton(frame: .zero, pullsDown: false)
    let inviteButton: CmuxDialogButtonView
    let status = ThemedLabel(wrappingLabelWithString: "")
    let empty = ThemedLabel(wrappingLabelWithString: "")
    let rowStack = NSStackView()
    /// The invite link, and Copy Invite Link (reads Copied a moment after a press). Always laid out, so the
    /// card keeps its size; clear and off until the chat has a link.
    let linkLabel = ThemedLabel(labelWithString: "")
    let copyButton: CmuxDialogButtonView
    let linkRow = NSStackView()
    private var shownRows: [AgentShareInviteSheetModel.Row] = []
    private var shownRemoving: Set<String> = []
    /// Bumped each time the card joins or leaves a window: a change callback from an older chain
    /// ends there, so one chain follows the model while the card shows and none after it closes.
    private var generation = 0

    package init(model: AgentShareInviteSheetModel, closeImage: NSImage) {
        self.model = model
        self.closeImage = closeImage
        inviteButton = CmuxDialogButtonView(standalone: CmuxDialogButton(id: "invite", title: model.inviteTitle, role: .default),
                                            target: nil, action: #selector(invitePressed))
        copyButton = CmuxDialogButtonView(CmuxDialogButton(id: "copyLink", title: model.copyLinkTitle, role: .default), hint: nil, quiet: true,
                                          target: nil, action: #selector(copyPressed))
        super.init(frame: .zero)
        inviteButton.target = self
        copyButton.target = self
        inviteButton.identifier = NSUserInterfaceItemIdentifier("cmux.agentShare.invites.invite")
        let content = build()
        let size = content.fittingSize
        content.removeFromSuperview()
        let holder = NSView(frame: NSRect(origin: .zero, size: size))
        holder.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: holder.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: holder.trailingAnchor),
            content.topAnchor.constraint(equalTo: holder.topAnchor),
            content.bottomAnchor.constraint(equalTo: holder.bottomAnchor)
        ])
        let surface = Glass.makeSurface(.sheet, content: holder)
        surface.translatesAutoresizingMaskIntoConstraints = true
        surface.frame = NSRect(origin: .zero, size: size)
        surface.autoresizingMask = [.width, .height]
        addSubview(surface)
        setFrameSize(size)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilitySubrole(.dialog)
        setAccessibilityLabel(model.title)
        setAccessibilityModal(true)
        identifier = NSUserInterfaceItemIdentifier("cmux.agentShare.invites")
        update()
    }

    @available(*, unavailable)
    package required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") } // crash-allow: never decoded from a nib

    /// Gives the keyboard to the account field once the card is in a window.
    package func focusField() {
        window?.makeFirstResponder(field)
    }

    /// Follows the model while the card is in a window (the overlay host detaches and re-attaches
    /// it as it presents), and stops when it leaves.
    override package func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        generation += 1
        guard window != nil else { return }
        follow(generation)
        focusField()
    }

    override package func cancelOperation(_ sender: Any?) { onClose?() }

    // MARK: Following the model

    private func follow(_ chain: Int) {
        guard chain == generation, window != nil else { return }
        withObservationTracking {
            update()
        } onChange: { [weak self] in
            // task-owner: one redraw per model change; ends when the card leaves its window
            Task { @MainActor [weak self] in self?.follow(chain) }
        }
    }

    /// Draws the model: the field (only when it differs, so typing keeps its caret), the role, Invite,
    /// the status line and the rows (rebuilt only when they or a running Remove changed).
    func update() {
        if field.stringValue != model.account { field.stringValue = model.account }
        if let item = rolePopup.itemArray.first(where: { $0.representedObject as? String == model.role }), rolePopup.selectedItem !== item {
            rolePopup.select(item)
        }
        inviteButton.isEnabled = model.canInvite
        status.stringValue = model.status ?? model.roleDetail
        status.ink = model.status == nil ? .secondary : .danger
        let link = model.inviteLink
        if linkLabel.stringValue != (link ?? "") { linkLabel.stringValue = link ?? "" }
        linkRow.alphaValue = link == nil ? 0 : 1
        copyButton.isEnabled = link != nil
        let copyTitle = model.copied ? model.copiedTitle : model.copyLinkTitle
        if copyButton.button.title != copyTitle { copyButton.retitle(copyTitle) }
        let rows = model.rows
        let removing = model.removing
        guard rows != shownRows || removing != shownRemoving || rowStack.arrangedSubviews.isEmpty != rows.isEmpty else { return }
        shownRows = rows
        shownRemoving = removing
        for view in rowStack.arrangedSubviews {
            rowStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        empty.isHidden = !rows.isEmpty
        let sheet = self.model
        for row in rows {
            let view = AgentShareInviteRowView(account: row.account, detail: sheet.rowDetail(row), removeTitle: sheet.removeTitle,
                                               isRemoving: removing.contains(row.account)) {
                // task-owner: one Remove; the model ignores a second press for the same account meanwhile
                Task { await sheet.remove(row.account) }
            }
            rowStack.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: rowStack.widthAnchor).isActive = true
        }
    }

    // MARK: Actions

    @objc func invitePressed() {
        guard model.canInvite else { return }
        let sheet = self.model
        // task-owner: one Invite; the model refuses another while it runs
        Task { await sheet.invite() }
    }

    @objc func copyPressed() { model.copyLink() }

    @objc private func closePressed() { onClose?() }

    @objc private func roleChosen() {
        if let role = rolePopup.selectedItem?.representedObject as? String { model.role = role }
    }

    package func controlTextDidChange(_ notification: Notification) {
        model.account = field.stringValue
    }

    package func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            invitePressed()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onClose?()
            return true
        default:
            return false
        }
    }

    // MARK: Layout

    private func build() -> NSStackView {
        let padding = Metrics.space5
        let inner = Self.width - padding * 2
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Metrics.space3
        stack.edgeInsets = NSEdgeInsets(top: padding, left: padding, bottom: padding, right: padding)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.widthAnchor.constraint(equalToConstant: Self.width).isActive = true

        let title = Self.label(model.title, font: Typography.title, ink: .primary, width: inner - 24)
        title.maximumNumberOfLines = 2
        let close = NSButton(image: closeImage, target: self, action: #selector(closePressed))
        close.isBordered = false
        close.setAccessibilityLabel(model.closeTitle)
        close.identifier = NSUserInterfaceItemIdentifier("cmux.agentShare.invites.close")
        let header = NSStackView(views: [title, NSView(), close])
        header.orientation = .horizontal
        header.alignment = .top
        stack.addArrangedSubview(header)
        header.widthAnchor.constraint(equalToConstant: inner).isActive = true

        stack.addArrangedSubview(Self.label(model.intro, font: Typography.body, ink: .secondary, width: inner))

        field.font = Typography.body
        field.placeholderString = model.accountPlaceholder
        field.delegate = self
        field.identifier = NSUserInterfaceItemIdentifier("cmux.agentShare.invites.account")
        field.setAccessibilityLabel(model.accountPlaceholder)
        let box = ThemedFieldBox(field: field, height: 24 * Typography.userScale)
        box.setContentHuggingPriority(.defaultLow, for: .horizontal)
        for role in ["talk", "view"] {
            rolePopup.addItem(withTitle: model.roleTitle(role))
            rolePopup.lastItem?.representedObject = role
        }
        rolePopup.target = self
        rolePopup.action = #selector(roleChosen)
        rolePopup.identifier = NSUserInterfaceItemIdentifier("cmux.agentShare.invites.role")
        rolePopup.setContentHuggingPriority(.required, for: .horizontal)
        inviteButton.setContentHuggingPriority(.required, for: .horizontal)
        let inputs = NSStackView(views: [box, rolePopup, inviteButton])
        inputs.orientation = .horizontal
        inputs.spacing = Metrics.space2
        stack.addArrangedSubview(inputs)
        inputs.widthAnchor.constraint(equalToConstant: inner).isActive = true

        status.font = Typography.caption
        status.preferredMaxLayoutWidth = inner
        status.maximumNumberOfLines = 2
        status.identifier = NSUserInterfaceItemIdentifier("cmux.agentShare.invites.status")
        status.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(status)
        status.widthAnchor.constraint(equalToConstant: inner).isActive = true
        // Two lines of room always, so a refusal never pushes the list down.
        status.heightAnchor.constraint(equalToConstant: ceil(NSLayoutManager().defaultLineHeight(for: Typography.caption)) * 2).isActive = true

        stack.addArrangedSubview(linkView(width: inner))

        let list = listView(width: inner)
        stack.addArrangedSubview(list)

        stack.addArrangedSubview(Self.label(model.removeNote, font: Typography.caption, ink: .tertiary, width: inner))
        return stack
    }

    /// The invite link (middle-truncated) and Copy Invite Link, whose width fits Copied too, so its
    /// confirmation moves nothing.
    private func linkView(width: CGFloat) -> NSView {
        linkLabel.font = Typography.caption
        linkLabel.ink = .secondary
        linkLabel.lineBreakMode = .byTruncatingMiddle
        linkLabel.identifier = NSUserInterfaceItemIdentifier("cmux.agentShare.invites.link")
        linkLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        copyButton.identifier = NSUserInterfaceItemIdentifier("cmux.agentShare.invites.copyLink")
        copyButton.retitle(model.copiedTitle)
        let copiedWidth = copyButton.intrinsicContentSize.width
        copyButton.retitle(model.copyLinkTitle)
        copyButton.widthAnchor.constraint(equalToConstant: ceil(max(copiedWidth, copyButton.intrinsicContentSize.width))).isActive = true
        copyButton.setContentHuggingPriority(.required, for: .horizontal)
        copyButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        for view in [linkLabel, NSView(), copyButton] { linkRow.addArrangedSubview(view) }
        linkRow.orientation = .horizontal
        linkRow.alignment = .centerY
        linkRow.spacing = Metrics.space2
        linkRow.translatesAutoresizingMaskIntoConstraints = false
        linkRow.widthAnchor.constraint(equalToConstant: width).isActive = true
        return linkRow
    }

    /// The invitees in a fixed band that scrolls past four rows, with the empty line in the same place.
    private func listView(width: CGFloat) -> NSView {
        rowStack.orientation = .vertical
        rowStack.alignment = .leading
        rowStack.spacing = 0
        rowStack.translatesAutoresizingMaskIntoConstraints = false
        let document = Document()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(rowStack)
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document
        SystemScrollers.followThin(scroll)
        empty.stringValue = model.emptyText
        empty.font = Typography.body
        empty.ink = .tertiary
        empty.translatesAutoresizingMaskIntoConstraints = false
        let band = NSView()
        band.translatesAutoresizingMaskIntoConstraints = false
        band.addSubview(scroll)
        band.addSubview(empty)
        NSLayoutConstraint.activate([
            band.widthAnchor.constraint(equalToConstant: width),
            band.heightAnchor.constraint(equalToConstant: Self.listHeight),
            scroll.leadingAnchor.constraint(equalTo: band.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: band.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: band.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: band.bottomAnchor),
            empty.leadingAnchor.constraint(equalTo: band.leadingAnchor),
            empty.trailingAnchor.constraint(equalTo: band.trailingAnchor),
            empty.topAnchor.constraint(equalTo: band.topAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            rowStack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            rowStack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            rowStack.topAnchor.constraint(equalTo: document.topAnchor),
            rowStack.bottomAnchor.constraint(equalTo: document.bottomAnchor)
        ])
        return band
    }

    /// The list's document view: rows grow down from its top.
    private final class Document: NSView {
        override var isFlipped: Bool { true }
    }

    private static func label(_ text: String, font: NSFont, ink: ThemeInk, width: CGFloat) -> ThemedLabel {
        let label = ThemedLabel(wrappingLabelWithString: text)
        label.font = font
        label.ink = ink
        label.preferredMaxLayoutWidth = width
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(lessThanOrEqualToConstant: width).isActive = true
        return label
    }
}

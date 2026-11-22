public import AppKit
public import CmuxHomeCore
import CmuxNextDesign

/// "Invite to cmux-next…": one email address, and the invites still
/// waiting for someone to join. The host's `onSend` makes the invite (a
/// team invite for a verified team domain, else a DM invite; the owner
/// decides) and answers with the outcome.
public final class HomeInviteSheet: HomeSheetController, NSTextFieldDelegate {
    public var onSend: (ContactAddress) async -> HomeComposeOutcome = { _ in .offline }
    let email = HomeSheetController.field(placeholder: HomeConversationStrings.inviteEmail, identifier: "cmux.home.invite.email")
    let pendingTitle = NSTextField(labelWithString: HomeConversationStrings.invitePending)
    let pendingList = NSTextField(wrappingLabelWithString: "")
    private let pending: [String]

    /// `pending`: the addresses of invites nobody accepted yet.
    public init(prefill: String = "", pending: [String]) {
        self.pending = pending
        super.init(title: HomeConversationStrings.inviteTitle, primary: HomeConversationStrings.inviteSend)
        email.stringValue = prefill
    }

    override func addContent(to stack: NSStackView) {
        let body = NSTextField(wrappingLabelWithString: HomeConversationStrings.inviteBody)
        body.font = Typography.body
        body.preferredMaxLayoutWidth = 420 - 2 * Metrics.space6
        stack.addArrangedSubview(body)
        email.delegate = self
        stack.addArrangedSubview(email)
        pendingTitle.font = Typography.header
        stack.addArrangedSubview(pendingTitle)
        pendingList.font = Typography.caption
        pendingList.textColor = .secondaryLabelColor
        pendingList.stringValue = pending.isEmpty ? HomeConversationStrings.inviteNonePending : pending.joined(separator: "\n")
        pendingList.setAccessibilityIdentifier("cmux.home.invite.pending")
        stack.addArrangedSubview(pendingList)
    }

    public override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(email)
    }

    var address: ContactAddress? {
        guard let parsed = ContactAddress.parse(email.stringValue), parsed.isEmail else { return nil }
        return parsed
    }

    override var canSubmit: Bool { !email.stringValue.trimmingCharacters(in: .whitespaces).isEmpty }

    override func submit() {
        guard let address else {
            show(HomeConversationStrings.outcome(.invalidAddress(email.stringValue)))
            return
        }
        let send = onSend
        run { await send(address) }
    }

    public func controlTextDidChange(_ notification: Notification) { refreshPrimary() }
}

/// "New Chief…": a name for another Chief, which gets its own conversation.
public final class HomeNewChiefSheet: HomeSheetController, NSTextFieldDelegate {
    public var onCreate: (String) async -> HomeComposeOutcome = { _ in .offline }
    let name = HomeSheetController.field(placeholder: HomeConversationStrings.chiefName, identifier: "cmux.home.chief.name")
    static let maxLength = 100

    public init() {
        super.init(title: HomeConversationStrings.chiefTitle, primary: HomeConversationStrings.chiefCreate)
    }

    override func addContent(to stack: NSStackView) {
        let body = NSTextField(wrappingLabelWithString: HomeConversationStrings.chiefBody)
        body.font = Typography.body
        body.preferredMaxLayoutWidth = 420 - 2 * Metrics.space6
        stack.addArrangedSubview(body)
        name.delegate = self
        stack.addArrangedSubview(name)
    }

    public override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(name)
    }

    var trimmed: String { name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) }
    override var canSubmit: Bool { !trimmed.isEmpty && trimmed.count <= Self.maxLength }

    override func submit() {
        let chosen = trimmed
        let create = onCreate
        run { await create(chosen) }
    }

    public func controlTextDidChange(_ notification: Notification) { refreshPrimary() }
}

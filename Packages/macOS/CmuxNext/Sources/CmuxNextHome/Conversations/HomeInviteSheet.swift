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
    let pendingTitle = ThemedLabel(labelWithString: HomeConversationStrings.invitePending)
    let pendingList = ThemedLabel(wrappingLabelWithString: "")
    private let pending: [String]

    /// `pending`: the addresses of invites nobody accepted yet.
    public init(prefill: String = "", pending: [String]) {
        self.pending = pending
        super.init(title: HomeConversationStrings.inviteTitle, primary: HomeConversationStrings.inviteSend)
        email.stringValue = prefill
    }

    override func addContent(to stack: NSStackView) {
        let body = ThemedLabel(wrappingLabelWithString: HomeConversationStrings.inviteBody)
        body.font = Typography.body
        body.preferredMaxLayoutWidth = 420 - 2 * Metrics.space6
        stack.addArrangedSubview(body)
        email.delegate = self
        stack.addArrangedSubview(Self.boxed(email))
        pendingTitle.font = Typography.header
        stack.addArrangedSubview(pendingTitle)
        pendingList.font = Typography.caption
        pendingList.ink = .secondary
        pendingList.stringValue = pending.isEmpty ? HomeConversationStrings.inviteNonePending : pending.joined(separator: "\n")
        pendingList.setAccessibilityIdentifier("cmux.home.invite.pending")
        stack.addArrangedSubview(pendingList)
    }

    override var initialResponder: NSView? { email }

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

public import AppKit
public import CmuxHomeCore
import CmuxNextDesign

/// "Invite to <team>": one email address, and what a join costs the team before Send.
///
/// The confirmation step of every team invite (the Home menus, the palette, New Message's To:
/// field, and a CLI or agent run, which waits for the person here): it opens at once, reads the
/// team's plan through ``seatImpact`` while it shows, and keeps Send off until that line is on
/// screen. The host's ``onSend`` sends the invite and answers with the outcome; `.invited` closes it.
///
/// ```swift
/// let sheet = HomeTeamInviteSheet(team: "cmux", prefill: "leo@cmux.com")
/// sheet.seatImpact = { await facts() }
/// sheet.onSend = { address in await invite(address) }
/// HomeSheetPresenter().present(sheet, over: window)
/// ```
public final class HomeTeamInviteSheet: HomeSheetController, NSTextFieldDelegate {
    /// Reads what a join costs (the team API's detail); runs once, when the sheet shows.
    public var seatImpact: () async -> HomeTeamSeatImpact = { .unknown }
    /// Sends the invite to the address shown; `.invited` closes the sheet.
    public var onSend: (ContactAddress) async -> HomeComposeOutcome = { _ in .offline }
    let email = HomeSheetController.field(placeholder: HomeConversationStrings.inviteEmail, identifier: "cmux.home.teamInvite.email")
    let impactLabel = ThemedLabel(wrappingLabelWithString: HomeConversationStrings.teamInviteChecking)
    /// The cost line once read; nil while it is read.
    private(set) var impact: HomeTeamSeatImpact?
    private let team: String
    private let requestedByAgent: Bool
    // task-owner: the one read of the team's plan; cancelled when the sheet closes
    private var read: Task<Void, Never>?

    /// - Parameters:
    ///   - team: The team's name (the active team).
    ///   - prefill: The address to show (a To: token, an agent's request).
    ///   - requestedByAgent: Not the person's own gesture: a line asks them to check the address.
    public init(team: String, prefill: String = "", requestedByAgent: Bool = false) {
        self.team = team
        self.requestedByAgent = requestedByAgent
        super.init(title: HomeConversationStrings.teamInviteTitle(team), primary: HomeConversationStrings.inviteSend)
        email.stringValue = prefill
    }

    override var initialResponder: NSView? { email }

    override func addContent(to stack: NSStackView) {
        let width = 420 - 2 * Metrics.space6
        let body = ThemedLabel(wrappingLabelWithString: HomeConversationStrings.teamInviteBody(team))
        body.font = Typography.body
        body.preferredMaxLayoutWidth = width
        stack.addArrangedSubview(body)
        if requestedByAgent {
            let note = ThemedLabel(wrappingLabelWithString: HomeConversationStrings.teamInviteRequested)
            note.font = Typography.caption
            note.preferredMaxLayoutWidth = width
            note.setAccessibilityIdentifier("cmux.home.teamInvite.requested")
            stack.addArrangedSubview(note)
        }
        email.delegate = self
        stack.addArrangedSubview(Self.boxed(email))
        impactLabel.font = Typography.caption
        impactLabel.ink = .secondary
        impactLabel.preferredMaxLayoutWidth = width
        impactLabel.setAccessibilityIdentifier("cmux.home.teamInvite.seats")
        stack.addArrangedSubview(impactLabel)
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        let seatImpact = seatImpact
        read = Task { [weak self] in
            let impact = await seatImpact()
            guard !Task.isCancelled else { return }
            self?.show(impact: impact)
        }
    }

    /// Shows the cost line and lets Send go (unless the team refuses this person's invites).
    func show(impact: HomeTeamSeatImpact) {
        self.impact = impact
        impactLabel.stringValue = HomeConversationStrings.seatImpact(impact)
        refreshPrimary()
    }

    var address: ContactAddress? {
        guard let parsed = ContactAddress.parse(email.stringValue), parsed.isEmail else { return nil }
        return parsed
    }

    override var canSubmit: Bool {
        guard let impact, impact.allowsSending else { return false }
        return !email.stringValue.trimmingCharacters(in: .whitespaces).isEmpty
    }

    override func submit() {
        guard let address else {
            show(HomeConversationStrings.outcome(.invalidAddress(email.stringValue)))
            return
        }
        let send = onSend
        run { await send(address) }
    }

    override func close(showing id: ConversationID?) {
        read?.cancel()
        super.close(showing: id)
    }

    override func presentationEnded() {
        read?.cancel()
        super.presentationEnded()
    }

    public func controlTextDidChange(_ notification: Notification) { refreshPrimary() }
}

import AppKit

/// cmux: the pointer on the Chief's approval card (HomeApprovalRowProvider) in the transcript.
///
/// The card is a drawn row, so its buttons are rects of its layout: the press, the release, the
/// hover and the click all hit-test with ``HomeApprovalRowProvider/clickable(_:at:size:)`` at the
/// point in the row body (the same body rect, width and layout function the row bitmap draws
/// with). A press on a button is the button's: no selection, link drag or tapback hold starts, and
/// the release on the same button clicks it, as an AppKit button does. A thread view's card takes
/// its click on the press instead (PaneThread's monitor, `MessagesWindowView.hostControl`).
///
/// Before this, the transcript's click path (`clicked`) never asked the provider: only an open
/// thread view's `hostControl` did, so a click on Allow or Deny in the conversation itself only
/// focused the message box (PR 22639 dogfood: "the buttons don't work").
extension ChatController {
    /// One button of one shown card.
    struct ApprovalTarget: Equatable {
        var ref: PartRef
        var allow: Bool
    }

    /// The card button at `p` (the host's coordinates) that takes a click now.
    func approvalTarget(at p: CGPoint) -> ApprovalTarget? {
        guard let hit = demo?.hit(p) else { return nil }
        return approvalTarget(hit, at: p)
    }

    func approvalTarget(_ hit: MessagesWindowView.Hit, at p: CGPoint) -> ApprovalTarget? {
        guard case let .custom(c) = hit.row.part,
              let allow = HomeApprovalRowProvider.clickable(c, at: Self.bodyPoint(hit, p), size: hit.body.size) else { return nil }
        return ApprovalTarget(ref: hit.row.ref, allow: allow)
    }

    /// `p` in the hit row's body (origin at its top left, y down), as the row draws.
    static func bodyPoint(_ hit: MessagesWindowView.Hit, _ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x - hit.body.minX, y: p.y - hit.body.minY)
    }

    /// A click at `p` on a card of `hit`: true when it was a card's button (taken, even while the
    /// card takes no click), false off the buttons or on another row (the click goes on as on any bubble).
    func approvalClicked(_ hit: MessagesWindowView.Hit, at p: CGPoint) -> Bool {
        guard case let .custom(c) = hit.row.part, c.kind == HomeApprovalRowProvider.kind,
              let card = HomeApprovalRowProvider.payload(c) else { return false }
        let point = Self.bodyPoint(hit, p)
        guard let allow = HomeApprovalRowProvider.button(at: point, card, width: hit.body.width) else { return false }
        // A disabled button (a decision in flight, the card settled) takes the click and does nothing.
        guard card.takesClicks else { return true }
        if let why = HomeApprovalRowProvider.shared.click(c, ref: hit.row.ref, allow: allow) {
            showApprovalRefusal(why, ref: hit.row.ref)
        }
        return true
    }

    /// Shows `why` under the buttons of the card at `ref` now (this Mac's state already keeps it
    /// for the next rebuild, ``HomeApprovalRowProvider/click(_:ref:allow:)``). No change when this
    /// pane does not show that card.
    func showApprovalRefusal(_ why: String, ref: PartRef) {
        restyleApproval(ref) { card in
            card.error = why
            card.busy = false
            card.note = nil
            card.pointer = nil
        }
    }

    /// Changes the shown card at `ref` (the part as the transcript has it now, never an older
    /// copy) and draws it again; nothing when it is not a card or `change` leaves it as it was.
    func restyleApproval(_ ref: PartRef, _ change: (inout HomeApprovalRowProvider.Payload) -> Void) {
        guard let message = store?.state.conversation.messages.last(where: { $0.id == ref.messageId }),
              case let .custom(c)? = message.parts[checked: ref.partIndex], c.kind == HomeApprovalRowProvider.kind,
              var card = HomeApprovalRowProvider.payload(c) else { return }
        let before = card
        change(&card)
        guard card != before, let part = HomeApprovalRowProvider.custom(card) else { return }
        dispatch(.setCustomPart(ref.messageId, ref.partIndex, part))
    }

    // MARK: Press, release, hover

    /// A press at `p`: true when it went down on a card's button (pressed now).
    func approvalPressBegan(at p: CGPoint) -> Bool {
        approvalPress = nil
        guard let target = approvalTarget(at: p) else { return false }
        approvalPress = target
        setApprovalPointer(target, pressed: true)
        return true
    }

    /// A release at `p`: true when the press was a card button's (then a release on the same
    /// button clicks it; anywhere else it does nothing).
    func approvalPressEnded(at p: CGPoint) -> Bool {
        guard let press = approvalPress else { return false }
        approvalPress = nil
        if let hit = demo?.hit(p), approvalTarget(hit, at: p) == press { _ = approvalClicked(hit, at: p) }
        approvalPointerMoved(p)
        return true
    }

    /// The pointer moved to `p` (nil: it left the transcript): the button under it draws its
    /// hover, or its press while the press that went down on it is held.
    func approvalPointerMoved(_ p: CGPoint?) {
        let target = p.flatMap(approvalTarget(at:))
        if let press = approvalPress {
            // While pressed, only the pressed button reacts, as an AppKit button.
            setApprovalPointer(target == press ? press : nil, pressed: true)
        } else {
            setApprovalPointer(target, pressed: false)
        }
    }

    private func setApprovalPointer(_ target: ApprovalTarget?, pressed: Bool) {
        let pointer = target.map { HomeApprovalRowProvider.Pointer(allow: $0.allow, pressed: pressed) }
        let old = approvalPointer
        approvalPointer = target
        if let old, old.ref != target?.ref { restyleApproval(old.ref) { $0.pointer = nil } }
        if let target { restyleApproval(target.ref) { $0.pointer = pointer } }
    }
}

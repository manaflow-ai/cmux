import Foundation

/// The Add Server card's state flow and keys. The step is derived from the model's own state (the
/// draft, the candidate, the intents in flight, the last answer), so the card, the palette and a
/// reopen all read the same answer, and the click and the key run the same ``perform(_:)``.
/// Approving itself is ``approve()``: the same `lookupCode` / `approveCode` intents the headless
/// `server.addServer` path sends, so no second approval path exists.
extension ServerModel {
    /// Where the card is (see ``AddServerStep``).
    public var addServerStep: AddServerStep {
        if let name = lastApproved { return .added(name) }
        if let candidate, PairingCode.normalize(approval.code) == candidate.code {
            if isApproving { return .approving(candidate) }
            if let reject = lastReject { return .approveFailed(candidate, reject) }
            return .review(candidate)
        }
        guard PairingCode.isComplete(approval.code) else { return .enterCode }
        if let reject = lastReject { return .codeRefused(reject) }
        return .lookingUp
    }

    /// The footer: an Escape button and a Return button, or only Done once the server was added.
    public var addServerButtons: [AddServerButton] {
        switch addServerStep {
        case .added:
            [AddServerButton(action: .done, isDefault: true, enabled: true)]
        case .approveFailed:
            [AddServerButton(action: .cancel, isDefault: false, enabled: true),
             AddServerButton(action: .retry, isDefault: true, enabled: canApprove)]
        case .enterCode, .lookingUp, .codeRefused, .review, .approving:
            [AddServerButton(action: .cancel, isDefault: false, enabled: true),
             AddServerButton(action: .approve, isDefault: true, enabled: canApprove)]
        }
    }

    /// Runs a card button (its click or its key). Returns true when the card should close.
    @discardableResult
    public func perform(_ action: AddServerAction) -> Bool {
        switch action {
        case .approve, .retry:
            approve()
            return false
        case .done:
            lastApproved = nil
            return true
        case .cancel:
            cancelApproval()
            lastReject = nil
            lastApproved = nil
            return true
        }
    }

    /// The card opens: a result from the last opening never greets this one, and a code typed
    /// before the card closed is looked up again (its earlier answer may be stale).
    public func beginApproval() {
        lastApproved = nil
        lastReject = nil
        let code = PairingCode.normalize(approval.code)
        guard PairingCode.isComplete(approval.code), candidate?.code != code, !isLookingUp else { return }
        send(.lookupCode(code))
    }

    /// Opens the card on a code that arrived from outside (a pairing link, a script without the
    /// words): the person still checks the words and approves.
    public func beginApproval(code: String) {
        cancelApproval()
        lastApproved = nil
        lastReject = nil
        setApprovalCode(code)
    }

    private var isApproving: Bool {
        isPending { if case .approveCode = $0 { true } else { false } }
    }

    private var isLookingUp: Bool {
        isPending { if case .lookupCode = $0 { true } else { false } }
    }
}

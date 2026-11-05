/// A control of the Pair Another Machine card.
public nonisolated enum PairInviteAction: Equatable, Sendable {
    case copyCode, copyLine, copyInstallLine
    /// Approves the arrived machine. SECURITY: only the person's own click on it answers
    /// (``PairInviteCardPanel``); its key, an Accessibility press and ``PairInviteModel/perform(_:)``
    /// do nothing.
    case confirm
    /// Confirm again after a failed approve (the same person-click-only control).
    case retry
    case newCode
    case done
    case cancel

    /// Whether only the person's own click on the control answers it.
    public var isPersonClickOnly: Bool { self == .confirm || self == .retry }
}

/// A footer button: its action and its key. Whether it can be pressed now is
/// ``PairInviteModel/isEnabled(_:)``, read apart so typing the name redraws no footer.
public nonisolated struct PairInviteButton: Equatable, Sendable {
    public nonisolated enum Key: Equatable, Sendable { case `return`, escape }
    public var action: PairInviteAction
    /// The key that presses it; a Confirm shows as the default button but its key does nothing.
    public var key: Key?
}

extension PairInviteModel {
    /// The footer for the current step.
    public var buttons: [PairInviteButton] {
        let cancel = PairInviteButton(action: .cancel, key: .escape)
        switch step {
        case .minting, .showing, .lookingUp, .signedOut:
            return [cancel]
        case .review, .approving:
            return [cancel, PairInviteButton(action: .confirm, key: .return)]
        case .approveFailed:
            return [cancel, PairInviteButton(action: .retry, key: .return)]
        case .paired:
            return [PairInviteButton(action: .done, key: .return)]
        case .voided, .expired, .lost, .failed:
            return [cancel, PairInviteButton(action: .newCode, key: .return)]
        }
    }

    /// Whether `action`'s button can be pressed now (Confirm: a name, and no approve in flight).
    public func isEnabled(_ action: PairInviteAction) -> Bool {
        action.isPersonClickOnly ? canConfirm : true
    }

    /// Runs a control (its click or its key). Returns true when the card should close. Confirm and
    /// Try Again do nothing here: only the panel's person-click check calls ``confirm()``.
    @discardableResult
    public func perform(_ action: PairInviteAction) -> Bool {
        switch action {
        case .copyCode: copy(.code); return false
        case .copyLine: copy(.line); return false
        case .copyInstallLine: copy(.installLine); return false
        case .confirm, .retry: return false
        case .newCode:
            // task-owner: one mint per press; a newer mint or close() supersedes it (its generation).
            Task { [weak self] in await self?.mint() }
            return false
        case .done, .cancel:
            close()
            return true
        }
    }
}

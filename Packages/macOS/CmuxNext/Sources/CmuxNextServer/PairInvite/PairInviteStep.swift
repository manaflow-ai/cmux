import Foundation

/// What the Pair Another Machine card shows: the invite's phase (the mint, then the socket's frames, then the
/// countdown) and, once a machine arrived, Add Server's step for its code.
nonisolated enum PairInviteStep: Equatable, Sendable {
    case minting
    /// The invite shows; no machine has used it yet.
    case showing(PairInvite)
    /// A machine used it; its details are on their way.
    case lookingUp(PairInvite)
    case review(PairInvite, PairingCandidate)
    case approving(PairInvite, PairingCandidate)
    case approveFailed(PairInvite, PairingCandidate, String)
    /// Enrolled: the machine's name (or the host id when the approve was not this card's).
    case paired(String)
    /// A second machine used the code: nothing pairs with it.
    case voided
    case expired
    /// The socket closed before the invite ended.
    case lost
    case signedOut
    case failed(String)
}

/// The invite's phase from its frames alone.
private nonisolated enum PairInvitePhase: Equatable {
    case waiting
    case arrived(code: String)
    case paired(host: String)
    case voided, expired, lost

    /// One socket frame applied. A frame that comes after the invite ended changes nothing; the machine's own pairing
    /// outlives the invite, so an arrived machine's Confirm still answers after an expiry or a lost socket.
    func receive(_ frame: PairInviteFrame) -> PairInvitePhase {
        switch (self, frame) {
        case (.waiting, let .arrived(code)): .arrived(code: code)
        case (.arrived, let .arrived(code)): .arrived(code: code)
        case (.waiting, let .paired(host)), (.arrived, let .paired(host)): .paired(host: host)
        case (.waiting, .voided), (.arrived, .voided): .voided
        case (.waiting, .expired): .expired
        case (.waiting, .lost): .lost
        default: self
        }
    }
}

extension PairInviteModel {
    /// The card's step at `now`.
    func step(now: Date = Date()) -> PairInviteStep {
        if mint == .failed {
            if case let .refused(text)? = failure { return .failed(text) }
            return .signedOut
        }
        guard mint == .ready, let invite else { return .minting }
        let phase = frames.reduce(PairInvitePhase.waiting) { $0.receive($1) }
        switch phase {
        case .waiting:
            return now >= invite.expiresAt ? .expired : .showing(invite)
        case let .arrived(code):
            switch approver.addServerStep {
            case let .added(name): return .paired(name)
            case let .review(found) where found.code == code: return .review(invite, found)
            case let .approving(found) where found.code == code: return .approving(invite, found)
            case let .approveFailed(found, reject) where found.code == code: return .approveFailed(invite, found, reject)
            case let .codeRefused(text): return .failed(text)
            default: return .lookingUp(invite)
            }
        case let .paired(host):
            return .paired(approver.lastApproved ?? host)
        case .voided: return .voided
        case .expired: return .expired
        case .lost: return .lost
        }
    }
}

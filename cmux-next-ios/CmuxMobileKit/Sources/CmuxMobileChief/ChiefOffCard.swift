import Foundation

/// Home's card while the account's Cloud Chief does not answer because its
/// brain is off, so the Chief is never a silent one. Every production signup
/// gets a Hosted Chief whose brain signup leaves off; until its owner turns it
/// on, every message waits with nothing shown. The card says so and offers the
/// one action that fixes it (the Mac's Home and the classic app's Home say the
/// same, `HomeChiefBanner`). Who may turn it on is the service's call: a
/// refusal that says this account may not run the Chief's model shows as
/// ``unavailable``, with no button, since a retry would be refused the same way.
public enum ChiefOffCard: Equatable, Sendable {
    /// The brain is off: Turn On.
    case off
    /// Turn On was tapped and its answer has not come back.
    case turningOn
    /// Turning it on failed (no answer, a server error): Try Again.
    case failed
    /// The service refused because this account may not run the Chief's model.
    case unavailable

    /// Why a Turn On of one chief did not take.
    public struct Refusal: Equatable, Sendable {
        public enum Kind: Equatable, Sendable {
            /// Worth another tap: no answer, a server error, any other refusal.
            case retryable
            /// This account may not run the Chief's model (the service's owner list).
            case unavailable
        }

        public var chief: String
        public var kind: Kind

        public init(chief: String, kind: Kind) {
            self.chief = chief
            self.kind = kind
        }
    }

    /// The brain route's refusals that mean the account may not run the
    /// Chief's model (the API Worker's `configure`: not on the owner list, or
    /// a model this account cannot use).
    static let unavailableCodes: Set<String> = ["chief_claude_unavailable", "chief_model_unavailable"]

    /// What a failed Turn On of `chief` means for the card.
    static func refusal(of chief: String, for error: any Error) -> Refusal {
        if case let ChiefCloudError.refused(_, code, _) = error, unavailableCodes.contains(code) {
            return Refusal(chief: chief, kind: .unavailable)
        }
        return Refusal(chief: chief, kind: .retryable)
    }

    /// The card Home shows. None unless the chief Home would open has its
    /// brain off (`offChief`, from the last read). A Turn On in flight for it
    /// shows as turning on; its last refusal, while the brain is still off,
    /// as failed or unavailable. A refusal for another chief says nothing here.
    static func decide(offChief: String?, turningOn: String?, refusal: Refusal?) -> ChiefOffCard? {
        guard let offChief else { return nil }
        if turningOn == offChief { return .turningOn }
        guard let refusal, refusal.chief == offChief else { return .off }
        return refusal.kind == .unavailable ? .unavailable : .failed
    }

    /// Whether the card's button is there and takes a tap.
    public var offersTurnOn: Bool { self == .off || self == .failed }
}

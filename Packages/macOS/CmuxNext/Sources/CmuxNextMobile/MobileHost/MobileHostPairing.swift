public import Foundation

/// The iPhone host's pairing state for the signed-in user: the requests waiting for the person
/// (``MobileHostPairPrompts``) and the list of phones they allowed or refused (``MobileHostPairedDevices``),
/// with the steps that change both together: a phone asks, the person answers, a phone is forgotten.
///
/// A pure value: `IPhoneHostService` holds one and does what each step's result says (show the
/// prompt, save and push the list, end a phone's links), so every pairing decision is this type's.
public struct MobileHostPairing: Sendable, Equatable {
    /// The requests waiting for the person, and the anti-flood state.
    public var prompts = MobileHostPairPrompts()
    /// The signed-in user's list; nil while no one is signed in.
    public var paired: MobileHostPairedDevices?

    public init(prompts: MobileHostPairPrompts = MobileHostPairPrompts(), paired: MobileHostPairedDevices? = nil) {
        self.prompts = prompts
        self.paired = paired
    }

    /// What a phone's request did.
    public enum Ask: Sendable, Equatable {
        /// iPhone connections are off, or no one is signed in: nothing changed.
        case ignored
        /// The list already trusts or refused these keys: nothing changed (hostd may hold an older list).
        case known
        /// The test seed trusts the phone: the list now trusts it.
        case seeded
        /// The request carried this Mac's live pairing code (``MobileHostPairTokens``): the list now
        /// trusts the phone, and its earlier waiting request (from before it scanned) is gone.
        case redeemed
        /// The request went to the prompts, with this outcome.
        case prompted(MobileHostPairPrompts.Outcome)
    }

    /// Phone `request` asks to pair. `seedTrusts` (the DEBUG test seed) is read only for a request the
    /// list does not decide, and pairs only into the signed-in user's own list. `redeems` is asked next,
    /// with the list's user: true when the request carries this Mac's live pairing code for that list
    /// (it burns the code); the phone is then allowed once, in place of the person's Allow. A request
    /// that waits for the person never keeps its code.
    public mutating func ask(
        _ request: MobileHostPairRequest, allowed: Bool, userID: String?, at now: Date,
        seedTrusts: (MobileHostPairRequest) -> Bool,
        redeems: (MobileHostPairRequest, _ listUserID: String) -> Bool = { _, _ in false }
    ) -> Ask {
        guard allowed, var list = paired else { return .ignored }
        guard list.decision(for: request) == .ask else { return .known }
        if list.userID == userID, seedTrusts(request) {
            list.approve(request, at: now)
            paired = list
            return .seeded
        }
        var waiting = request
        waiting.pairToken = nil
        if request.pairToken != nil, redeems(request, list.userID) {
            list.approve(waiting, at: now)
            paired = list
            // An earlier request from this phone is answered: its prompt closes, so a stale Allow
            // cannot overwrite the keys just approved.
            prompts.forget(id: request.phoneDeviceID)
            return .redeemed
        }
        return .prompted(prompts.receive(waiting, at: now))
    }

    /// The person answered `request` (in its prompt or in Settings). Its prompt goes, Don't Allow quiets
    /// the prompts, and the answer is written to the list when the list is the signed-in user's.
    /// Returns whether the list changed.
    @discardableResult
    public mutating func decide(_ request: MobileHostPairRequest, allow: Bool, userID: String?, at now: Date) -> Bool {
        prompts.answer(id: request.phoneDeviceID, allowed: allow, at: now)
        guard var list = paired, list.userID == userID else { return false }
        if allow { list.approve(request, at: now) } else { list.deny(request) }
        paired = list
        return true
    }

    /// Phone `id` signed out or was removed in Settings: its waiting request and its pairing go.
    /// Returns whether there was a list to change.
    @discardableResult
    public mutating func revoke(id: String) -> Bool {
        prompts.forget(id: id)
        guard var list = paired else { return false }
        list.remove(id)
        paired = list
        return true
    }
}

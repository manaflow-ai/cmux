/// The Cloud approval holds (G8, cx-wb5.65) the person has answered, as their feed shows them. The
/// backend posts each hold as an approve item in the person's `FeedDO`; the item closes in the same
/// commit that takes the person's answer on any device (the phone, the dashboard, another Mac), and
/// the feed owner pushes that event to the Mac's mirror at once. The app records each closed hold
/// here, so a create flow knows the hold was answered without asking the server again (cmux#32354).
@MainActor
public final class CloudApprovalHolds {
    /// The requests whose approve item is closed. A closed item never opens again.
    private var answered: Set<String> = []

    public init() {}

    /// The feed owner's closed approve items, by the hold request each carries.
    public func recordAnswered(_ requests: some Sequence<String>) {
        let new = Set(requests).subtracting(answered)
        if !new.isEmpty { answered.formUnion(new) }
    }

    public func isAnswered(_ request: String) -> Bool { answered.contains(request) }
}

/// The Cloud approval holds (G8, cx-wb5.65) the person has answered, as their feed shows them. The
/// backend posts each hold as an approve item in the person's `FeedDO`; the item closes in the same
/// commit that takes the person's answer on any device (the phone, the dashboard, another Mac), and
/// the feed owner pushes that event to the Mac's mirror at once. The app records each closed hold
/// here, so a create flow knows the hold was answered without asking the server again (cmux#32354).
@MainActor
public final class CloudApprovalHolds {
    /// The team of each request whose approve item is closed. A closed item never opens again.
    private var answered: [String: String] = [:]

    public init() {}

    /// The feed owner's closed approve items: the hold request each carries and the team whose owner posted it.
    public func recordAnswered(_ holds: some Sequence<(request: String, team: String)>) {
        for hold in holds where answered[hold.request] != hold.team { answered[hold.request] = hold.team }
    }

    /// Whether `team`'s own item for `request` is closed; another team's closed item answers nothing for `team`.
    public func isAnswered(_ request: String, team: String) -> Bool { answered[request] == team }
}

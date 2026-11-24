/// What a window membership turn does, counted for `WorkspacePlacementCostTests`: one new workspace does work
/// O(changed), in a session of 826 workspaces as in one of 60 (CLAUDE.md "Go past Chrome": a local model change is
/// O(changed items), never O(session)). Plain adds on the main actor, kept by the app's `WindowRegistryStore`
/// (`membershipWork`).
///
/// - `orderBuilds`: builds of one daemon's workspace order (`WindowRegistryStore.orderBuild`); each one reads every
///   workspace of that daemon and the sidebar document's sections.
/// - `answerWrites`: writes of an observed per-workspace entry (`incognitoByWorkspace`, `ownerByWorkspace`); each
///   one reads its slot through the observation registrar, also when the value is equal.
public nonisolated struct WindowMembershipWork: Equatable, Sendable, CustomStringConvertible {
    public var orderBuilds = 0
    public var answerWrites = 0

    public init() {}

    public var description: String {
        "order builds \(orderBuilds), answer writes \(answerWrites)"
    }
}

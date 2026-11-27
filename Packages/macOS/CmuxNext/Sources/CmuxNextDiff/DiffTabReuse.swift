/// What a chat's open changes in the diff tab it reuses (D1, D2, ``DiffOpenSource/change(shownTurn:_:)``).
public nonisolated enum DiffTabChange: Equatable, Sendable {
    /// Nothing: no turn named, or the tab has this one.
    case keep
    /// The tab's Last turn shows this turn from then on; the page is not reloaded, so the
    /// reader keeps the scope, place and commit form they have.
    case newTurn
    /// The tab reloads on the turn, at its file (a card).
    case reload
}

/// Which diff tab an open takes, and what a chat's open changes there (D1, D2). One tab per
/// repository and scope in the window, as before. A turn open (an edited-files card, `.turn`)
/// takes the window's tab of the repository in any scope, as Codex's one Review tab does, and a
/// default open (the header's Changes) also takes a tab a card moved to its turn. Pure, so the
/// routing is tested without a window.
extension DiffOpenSource {
    /// Whether a tab of `root` that opened on `source` is the one an open of this source in
    /// `wantedRoot` selects.
    public func reuses(root: String?, source: DiffOpenSource, for wantedRoot: String) -> Bool {
        guard root == wantedRoot else { return false }
        return self == .turn || source == self || (self == .default && source == .turn)
    }

    /// What an open of this source with `turn` changes in a reused tab that has `shownTurn`.
    public func change(shownTurn: DiffTurn?, _ turn: DiffTurn?) -> DiffTabChange {
        guard let turn else { return .keep }
        if self == .turn { return .reload }
        return shownTurn?.from == turn.from && shownTurn?.to == turn.to ? .keep : .newTurn
    }
}

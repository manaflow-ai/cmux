import CmuxHomeCore

/// One `HomeStreamMapper` per running reply, by its turn key: several replies can stream at once
/// (plans/cmux-next/home-chat-pipeline-DESIGN.md, 2.1), and each keeps its own rendered lines.
/// A turn's mapper goes when its reply leaves the screen (`keep(only:)`).
///
/// Main thread only (the projection's).
final class HomeStreamMappers {
    private var byTurn: [IdempotencyKey: HomeStreamMapper] = [:]

    /// The mapper of `turn`'s reply, made on its first token.
    func mapper(_ turn: IdempotencyKey) -> HomeStreamMapper {
        if let m = byTurn[turn] { return m }
        let m = HomeStreamMapper()
        byTurn[turn] = m
        return m
    }

    /// Drops the mappers of replies no longer on screen.
    func keep(only turns: Set<IdempotencyKey>) {
        guard byTurn.count > turns.count || byTurn.keys.contains(where: { !turns.contains($0) }) else { return }
        byTurn = byTurn.filter { turns.contains($0.key) }
    }
}

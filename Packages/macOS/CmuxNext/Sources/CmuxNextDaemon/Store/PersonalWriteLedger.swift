/// A personal organization write (a workspace's group and place, a group's order, name, color, pin or icon) that the
/// sidebar already shows. A missed deadline or a lost connection is not a refusal: the daemon may still apply the
/// write, so the sidebar keeps what the person did and the write goes again until the daemon answers, never undone for
/// a slow daemon (Leo, 2026-11-03: "we have the optimistic moving/animation which is good... THEN WE UNDO IT!!! WHICH
/// IS BAD!!!"). Only a definite refusal rolls the change back.
///
/// Every write retried here sets absolute values (a group, an index, a name), so sending it again lands the same state.
///
/// The ledger also says which pending write is the newest for each thing it sets: a newer write to the same workspace (or group
/// field) supersedes that part of a write still being retried, so the last write wins and an older retry never puts back what the
/// person changed since.
@MainActor
public final class PersonalWriteLedger {
    private var latest: [String: UInt64] = [:]
    private var serial: UInt64 = 0

    public init() {}

    /// One write's claim on `keys`, made when the person acted.
    public struct Claim: Sendable {
        let keys: [String]
        let generation: UInt64
    }

    /// Claims `keys` for a new write: every earlier claim on any of them is superseded.
    public func claim(_ keys: [String]) -> Claim {
        serial += 1
        for key in keys { latest[key] = serial }
        return Claim(keys: keys, generation: serial)
    }

    /// Claims session-qualified workspaces' group and place.
    public func claim(workspaces: [(session: String, key: String)]) -> Claim { claim(workspaces.map { Self.workspace(session: $0.session, key: $0.key) }) }

    /// Claims `fields` of personal group `id`.
    public func claim(group id: String, _ fields: String...) -> Claim { claim(fields.map { Self.group(id, $0) }) }

    /// Whether later writes claimed every one of `claim`'s keys, so nothing is left for it to send. A write that set
    /// several workspaces still goes for the ones no later write took: a move of [a, b] followed by a move of a alone
    /// keeps b where the person put it.
    public func isSuperseded(_ claim: Claim) -> Bool {
        claim.keys.allSatisfy { !isCurrent(claim, $0) }
    }

    /// Whether `claim` is still the newest write to `key`; a write sends only its current keys.
    public func isCurrent(_ claim: Claim, _ key: String) -> Bool { (latest[key] ?? 0) <= claim.generation }

    /// Whether `claim` is still the newest write to a session-qualified workspace's group and place.
    public func isCurrent(_ claim: Claim, workspace session: String, _ key: String) -> Bool {
        isCurrent(claim, Self.workspace(session: session, key: key))
    }

    /// The key of a session-qualified workspace's group and place.
    public static func workspace(session: String, key: String) -> String { "ws:\(session)/\(key)" }

    /// The key of one field of a personal group.
    public static func group(_ id: String, _ field: String) -> String { "group:\(id):\(field)" }

    /// Whether `error` leaves the write's outcome unknown, so sending it again can tell: a missed deadline, no
    /// connection, a connection that closed or restarted, or a refusal the daemon marked retryable.
    public static func isUnanswered(_ error: any Error) -> Bool {
        guard let error = error as? DaemonError else { return false }
        if error.isLostConnection { return true }
        if case .command(_, _, _, _, let retryable) = error { return retryable == true }
        return false
    }
}

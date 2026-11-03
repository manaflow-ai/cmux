public import Observation

/// Every acpmux session's lane (cx-v9k2f): this Mac's and the acpmux peers' it mirrors, from the
/// same `_acpmux/watch` as the turn states (`AgentTurnStateFeed`). The sidebar's Priority view,
/// Chief item and session tree read it.
///
/// Reading ``lanes`` observes every session: any lane's change notifies the reader. A reader that
/// needs one session (a sidebar row, its "Now:" line) reads ``lane(_:)`` instead, which observes that
/// session alone, and a reader that needs only what links a session to its folder and pull requests
/// (and its state) reads ``links(_:)``, which a new step leaves alone. A working agent changes its lane many
/// times a second, so a whole-store read in a per-row mapping maps every row on every agent event
/// (sidebar-lag-DESIGN.md).
@Observable @MainActor
public final class AgentLaneStore {
    public static let shared = AgentLaneStore()
    /// The Chief home's lanes (its subagents), apart from this Mac's own: the Priority view reads both.
    public static let chief = AgentLaneStore()

    /// Keyed by session id; empty while the watch is down. Writing it updates the per-session
    /// cells of ``lane(_:)`` and ``links(_:)`` whose value changed, and notifies readers of the whole map.
    public var lanes: [String: AgentActivityLane] {
        get {
            access(keyPath: \.lanes)
            return storage
        }
        set {
            withMutation(keyPath: \.lanes) { storage = newValue }
            waiting = Set(newValue.compactMap { $0.value.state == .input ? $0.key : nil })
            syncCells()
            syncChiefParticipants()
        }
    }

    /// The sessions whose lane waits for the person (`.input`: a permission prompt or a question),
    /// kept with every write, so a reader that wants only those (Go to Next Agent Needing Input,
    /// the menu bar's count) reads a few lanes instead of ranking every one. Not observed: read
    /// it when it is used.
    @ObservationIgnored public private(set) var waiting: Set<String> = []

    /// Writes one session's lane (nil: it ended), as ``lanes``' setter does for that session, but
    /// in place and keeping ``waiting`` by that session alone: the watch's per-session changes,
    /// many a second while an agent works, never copy or rescan the map.
    public func set(_ session: String, _ lane: AgentActivityLane?) {
        let ownedBefore = Self.chiefOwnership(storage[session])
        withMutation(keyPath: \.lanes) { storage[session] = lane }
        if lane?.state == .input { waiting.insert(session) } else { waiting.remove(session) }
        syncCells()
        // Rescan only when this session's Chief tags change, not on every step of its output.
        if Self.chiefOwnership(lane) != ownedBefore { syncChiefParticipants() }
    }

    /// A lane's Chief ownership pair (its `mux.children` key and participant), on this Mac only.
    private static func chiefOwnership(_ lane: AgentActivityLane?) -> [String]? {
        guard let lane, lane.peer == nil, let key = lane.chiefChildren, let chief = lane.chiefParticipant else { return nil }
        return [key, chief]
    }

    private func syncChiefParticipants() {
        let identities = Dictionary(storage.values.compactMap { lane -> (String, String)? in
            Self.chiefOwnership(lane).map { ($0[0], $0[1]) }
        }, uniquingKeysWith: { first, _ in first })
        if chiefParticipants != identities { chiefParticipants = identities }
    }
    @ObservationIgnored private var storage: [String: AgentActivityLane] = [:]
    /// One observable cell per session a reader asked for (``lane(_:)``, ``links(_:)``).
    @ObservationIgnored private var cells: [String: AgentLaneCell] = [:]
    /// The acpmux socket whose watch fills the store (set by `AgentTurnStateFeed`), for requests
    /// about its sessions such as the Priority view's Archive.
    @ObservationIgnored public var socketPath: String?
    /// The watch is up and has delivered its page: `lanes` is every session, not a gap.
    public var live = false

    /// Changes only when ownership changes; ordinary lane output does not remap every row.
    public private(set) var chiefParticipants: [String: String] = [:]

    public init() {}

    /// The lane of `session`, observing that session only: another session's change does not
    /// notify the reader.
    public func lane(_ session: String) -> AgentActivityLane? { cell(session).lane }

    /// Whether the watch currently has a lane for `session`, observing only presence changes.
    /// A lane's state may change many times per second; structural sidebar readers must not
    /// rebuild when that happens.
    public func sessionIsLive(_ session: String) -> Bool { cell(session).hasLiveSession }

    /// What links `session` to its folder, its pull requests and the chat that started it, and its
    /// state, observing only that: a new step of the session does not notify the reader.
    public func links(_ session: String) -> AgentLaneLinks? { cell(session).links }

    /// The chat key for `session`, observing only the chat binding. A turn-state update leaves
    /// this value alone, so chat-history projections do not re-scan every tab while an agent works.
    public func chat(_ session: String) -> String? { cell(session).chat }

    private func cell(_ session: String) -> AgentLaneCell {
        if let cell = cells[session] { return cell }
        let cell = AgentLaneCell(storage[session])
        cells[session] = cell
        return cell
    }

    /// Writes each cell whose session's lane changed; drops cells of ended sessions once they are
    /// told (their readers re-read and get a fresh cell).
    private func syncCells() {
        guard !cells.isEmpty else { return }
        var ended: [String] = []
        for (session, cell) in cells {
            let lane = storage[session]
            let wasLive = cell.hasLiveSession
            cell.update(lane)
            if wasLive, lane == nil { ended.append(session) }
        }
        for session in ended { cells[session] = nil }
    }
}

/// One pending `apps-set`: sent to the supervisor, not yet answered.
public nonisolated struct AppIntent: Sendable, Hashable, Identifiable {
    /// The idempotency key; resent unchanged after a reconnect.
    public var id: String
    public var app: String
    public var change: AppChange
    public var origin: AppOrigin

    public init(id: String, app: String, change: AppChange, origin: AppOrigin) {
        self.id = id
        self.app = app
        self.change = change
        self.origin = origin
    }
}

/// The client's projection of the supervisor's install mirror
/// (OWNERSHIP-PRINCIPLES "Clients are projections"): a confirmed mirror
/// written only by owner replies (`apps-list`, the reply of `apps-set`),
/// plus one ordered log of pending intents. The visible state is the mirror
/// with the pending intents applied in order; an intent leaves the log on
/// its reply (echo) or its reject. Pure, so property tests drive it.
public nonisolated struct AppsProjection: Sendable, Hashable {
    /// Confirmed records in the owner's list order.
    public private(set) var mirror: [AppRecord] = []
    /// Revision of the last applied `apps-list`; nil before the first.
    public private(set) var revision: UInt64?
    public private(set) var pending: [AppIntent] = []
    /// Ids of `apps-list` requests: a reply to a request sent before the
    /// last confirmed `apps-set` may predate that commit and is ignored
    /// (requests on one connection are answered in order).
    private var nextListRequest = 0
    private var listFloor = 0

    public init() {}

    /// Numbers an `apps-list` request; pass the id to `applyList`.
    public mutating func listRequested() -> Int {
        defer { nextListRequest += 1 }
        return nextListRequest
    }

    /// A new connection: the supervisor may have restarted and count
    /// revisions from scratch, so the next list applies whatever it says.
    public mutating func newConnection() {
        revision = nil
    }

    /// The records the UI shows.
    public var visible: [AppRecord] { mirror.map(visible) }

    public func visible(_ id: String) -> AppRecord? { mirror.first { $0.id == id }.map(visible) }

    private func visible(_ record: AppRecord) -> AppRecord {
        pending.reduce(record) { record, intent in intent.app == record.id ? intent.change.applied(to: record) : record }
    }

    /// An `apps-list` reply. An older revision than the one applied is
    /// stale (a reply that crossed a newer one) and ignored, and so is a
    /// reply to a request sent before the last confirmed change.
    public mutating func applyList(_ records: [AppRecord], revision: UInt64?, request: Int? = nil) {
        if let request, request < listFloor { return }
        if let revision, let current = self.revision, revision < current { return }
        mirror = records
        if let revision { self.revision = revision }
    }

    public mutating func enqueue(_ intent: AppIntent) {
        guard !pending.contains(where: { $0.id == intent.id }) else { return }
        pending.append(intent)
    }

    /// The owner committed the intent: its reply is the app's record.
    public mutating func confirm(_ key: String, record: AppRecord) {
        pending.removeAll { $0.id == key }
        listFloor = nextListRequest
        if let index = mirror.firstIndex(where: { $0.id == record.id }) { mirror[index] = record } else { mirror.append(record) }
    }

    /// The owner refused the intent: it leaves, the app shows the mirror again.
    public mutating func reject(_ key: String) {
        pending.removeAll { $0.id == key }
    }

    /// Whether an intent of `app` is still waiting for its reply.
    public func isPending(_ app: String) -> Bool { pending.contains { $0.app == app } }
}

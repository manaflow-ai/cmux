/// The Home conversations kept live (`HomeService.sessions`): each one a window shows or with a
/// send not yet confirmed, plus the `idleCap` others used most recently. An older one is dropped
/// and loads again on its next use, so a reconnect reloads only this set. Before, every
/// conversation used once stayed live for the app's life and each reconnect reloaded all of them.
@MainActor
public struct HomeLiveSessions {
    /// How many conversations nobody shows stay live beside the shown ones.
    public static let defaultIdleCap = 8

    public let idleCap: Int
    private var byID: [String: HomeConversationSession] = [:]
    /// Ids, least recently used first.
    private var order: [String] = []

    public init(idleCap: Int = HomeLiveSessions.defaultIdleCap) {
        self.idleCap = idleCap
    }

    public subscript(id: String) -> HomeConversationSession? { byID[id] }

    /// Every live session (a reconnect reloads these).
    public var values: Dictionary<String, HomeConversationSession>.Values { byID.values }

    public var count: Int { byID.count }

    /// `id` was used now: it goes to the end of the order.
    public mutating func touch(_ id: String) {
        guard byID[id] != nil, order.last != id else { return }
        order.removeAll { $0 == id }
        order.append(id)
    }

    /// The live session of `id`, marked used now; nil when it is not live (the caller makes and
    /// loads it again).
    public mutating func use(_ id: String) -> HomeConversationSession? {
        guard let session = byID[id] else { return nil }
        touch(id)
        return session
    }

    /// The live set a reconnect reloads: those confirmed since they were held drop first, so only
    /// the shown, the unconfirmed and the `idleCap` used last load again.
    public mutating func trimmed() -> [HomeConversationSession] {
        trim()
        return Array(byID.values)
    }

    /// Adds `session` as the most recently used, then drops the least recently used idle ones past
    /// `idleCap`. Returns the ids it dropped.
    @discardableResult
    public mutating func insert(_ session: HomeConversationSession, for id: String) -> [String] {
        if byID[id] != nil { order.removeAll { $0 == id } }
        byID[id] = session
        order.append(id)
        return trim()
    }

    /// Drops the least recently used sessions nobody shows and with nothing unconfirmed, keeping
    /// `idleCap` of them.
    @discardableResult
    public mutating func trim() -> [String] {
        var idle = order.filter { byID[$0]?.isHeld == false }
        guard idle.count > idleCap else { return [] }
        idle.removeLast(idleCap)
        let dropped = Set(idle)
        for id in idle { byID[id] = nil }
        order.removeAll { dropped.contains($0) }
        return idle
    }
}

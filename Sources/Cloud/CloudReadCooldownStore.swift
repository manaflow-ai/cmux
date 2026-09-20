import Foundation

/// Bounds retained throttling state without turning eviction into an early retry.
struct CloudReadCooldownStore: Sendable {
    private let capacity: Int
    private var session: Session?
    private var cooldowns: [CloudReadRequestCoordinator.Key: Cooldown] = [:]
    private var overflow: Cooldown?

    init(capacity: Int = 256) {
        self.capacity = max(1, capacity)
    }

    var retainedCount: Int { cooldowns.count + (overflow == nil ? 0 : 1) }

    mutating func activateSession(for key: CloudReadRequestCoordinator.Key) {
        let incoming = Session(accountID: key.accountID, generation: key.generation)
        guard incoming != session else { return }
        if let session {
            // AuthCoordinator generations increase across account replacement.
            // An old read admitted late cannot reactivate a retired session.
            guard let generation = incoming.generation else { return }
            if let previousGeneration = session.generation, generation <= previousGeneration { return }
        }
        session = incoming
        cooldowns.removeAll(keepingCapacity: true)
        overflow = nil
    }

    mutating func response(for key: CloudReadRequestCoordinator.Key, now: TimeInterval) -> CloudReadRequestCoordinator.Response? {
        guard matchesSession(key) else { return nil }
        prune(now: now)
        return (cooldowns[key] ?? overflow)?.response
    }

    mutating func record(
        _ key: CloudReadRequestCoordinator.Key, until: TimeInterval, now: TimeInterval,
        response: CloudReadRequestCoordinator.Response
    ) {
        guard matchesSession(key), until > now else { return }
        prune(now: now)
        let compactResponse = CloudReadRequestCoordinator.Response(
            data: Data(#"{"error":"rate_limited"}"#.utf8),
            http: HTTPURLResponse(
                url: response.http.url ?? URL(fileURLWithPath: "/"), statusCode: 429,
                httpVersion: nil, headerFields: nil
            )!
        )
        let cooldown = Cooldown(until: until, response: compactResponse)
        if let existing = cooldowns[key] {
            if until > existing.until { cooldowns[key] = cooldown }
        } else if cooldowns.count < capacity {
            cooldowns[key] = cooldown
        } else if until > (overflow?.until ?? now) {
            // Once full, retain one conservative session barrier instead of
            // arbitrary keys/bodies. Unknown paths may wait longer at capacity;
            // no forgotten path can retry before its server minimum.
            overflow = cooldown
        }
    }

    private func matchesSession(_ key: CloudReadRequestCoordinator.Key) -> Bool {
        session == Session(accountID: key.accountID, generation: key.generation)
    }

    private mutating func prune(now: TimeInterval) {
        cooldowns = cooldowns.filter { $0.value.until > now }
        if let overflow, overflow.until <= now { self.overflow = nil }
    }
}

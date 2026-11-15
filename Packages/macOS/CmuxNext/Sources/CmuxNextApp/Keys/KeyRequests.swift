import Foundation
import Observation

/// The key requests agents sent with `cmux keys request NAME` (control method `keys.request`,
/// ``AppControl/registerKeysMethods(_:)``) that wait for the person in Settings > Keys
/// (design/settings-keys.md). Leo, 2026-11-15: "letting agents safely write keys and store them or
/// enter them jnto whatever".
///
/// In memory only, never written anywhere: a request names a key and why, never a value. Bounded
/// (``limit``): a new ask past it ends the oldest as cancelled. A new ask for a name that already
/// waits replaces the old one, which ends as cancelled. Each request ends exactly once: stored
/// (the person's value went to `cmux keys put`), declined, or cancelled (replaced, pushed out, or
/// its asker's connection dropped). The waiting CLI gets that end through ``Ask/end``.
@MainActor @Observable
final class KeyRequests {
    /// How a request ended, for the agent waiting on it.
    enum Outcome: Sendable, Equatable {
        case stored(name: String)
        case declined
        case cancelled
    }

    /// One request as the person sees it.
    struct Request: Sendable, Equatable {
        var id: String
        var name: String
        var purpose: String
        var hosts: [String]
        /// `--ttl` as the agent gave it (`90d`), passed on to `cmux keys put`; nil keeps the CLI's default.
        var ttl: String?
        /// Who asked, as the CLI names it (`CLAUDE_CODE_SESSION_ID=…`).
        var requester: String
        var askedAt: Date
    }

    /// The app's one list (the control method and Settings > Keys share it).
    static let app = KeyRequests()

    /// The most requests that wait at once.
    static let limit = 16

    @ObservationIgnored private var waiting: [(request: Request, end: (Outcome) -> Void)] = []
    /// Bumped on every change, so a page watching it reads the list again (no value in it).
    private(set) var revision = 0
    @ObservationIgnored private var next = 0

    init() {}

    /// The waiting requests, oldest first.
    var requests: [Request] {
        _ = revision
        return waiting.map(\.request)
    }

    func request(_ id: String) -> Request? {
        _ = revision
        return waiting.first { $0.request.id == id }?.request
    }

    /// Adds a request; `end` runs once, on the main actor, when it ends. Answers its id.
    @discardableResult
    func add(name: String, purpose: String, hosts: [String], ttl: String?, requester: String,
             at date: Date = Date(), end: @escaping (Outcome) -> Void) -> String {
        next += 1
        let id = "kr_\(next)_\(UUID().uuidString.prefix(8).lowercased())"
        // Same name: the newer ask wins; the older one's agent hears cancelled.
        let replaced = waiting.filter { $0.request.name == name }
        waiting.removeAll { $0.request.name == name }
        var dropped: [(request: Request, end: (Outcome) -> Void)] = []
        while waiting.count >= Self.limit { dropped.append(waiting.removeFirst()) }
        waiting.append((Request(id: id, name: name, purpose: purpose, hosts: hosts, ttl: ttl, requester: requester, askedAt: date), end))
        revision += 1
        for old in replaced + dropped { old.end(.cancelled) }
        return id
    }

    /// Ends request `id` with `outcome`; false when it no longer waits (ended already).
    @discardableResult
    func finish(_ id: String, _ outcome: Outcome) -> Bool {
        guard let index = waiting.firstIndex(where: { $0.request.id == id }) else { return false }
        let ended = waiting.remove(at: index)
        revision += 1
        ended.end(outcome)
        return true
    }
}

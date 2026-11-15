package import Foundation
import CmuxNextWakeups
import Observation

/// The key requests agents sent with `cmux keys request NAME` (control method `keys.request`,
/// ``controlMethod``) that wait for the person in Settings > Keys (design/settings-keys.md).
/// Leo, 2026-11-15: "letting agents safely write keys and store them or enter them jnto whatever".
///
/// In memory only, never written anywhere: a request names a key and why, never a value. Bounded
/// (``limit``): a new ask past it ends the oldest as cancelled. A new ask for a name that already
/// waits replaces the old one, which ends as cancelled. Each request ends exactly once: stored
/// (the person's value went to `cmux keys put`), declined, or cancelled (replaced, pushed out, or
/// its asker's connection dropped). The App makes one at its composition root and passes it to the
/// control method, the Settings page and the banners.
@MainActor @Observable
package final class KeyRequests {
    /// How a request ended, for the agent waiting on it.
    package nonisolated enum Outcome: Sendable, Equatable {
        case stored(name: String)
        case declined
        case cancelled
    }

    /// One request as the person sees it.
    package nonisolated struct Request: Sendable, Equatable {
        package var id: String
        package var name: String
        package var purpose: String
        package var hosts: [String]
        /// `--ttl` as the agent gave it (`90d`), passed on to `cmux keys put`; nil keeps the CLI's default.
        package var ttl: String?
        /// Who asked, as the CLI names it (`CLAUDE_CODE_SESSION_ID=…`).
        package var requester: String
        package var askedAt: Date
    }

    /// The most requests that wait at once.
    package static let limit = 16
    /// How long a request may wait for the person: a week, so the CLI's own wait (none) decides.
    package nonisolated static let longestWait: Duration = .seconds(7 * 24 * 3_600)

    @ObservationIgnored private var waiting: [(request: Request, end: (Outcome) -> Void)] = []
    /// Ids ended before their ask was added (the asker's connection closed first); bounded.
    @ObservationIgnored private var endedEarly: [String] = []
    /// Bumped on every change, so a page watching it reads the list again (no value in it).
    package private(set) var revision = 0
    /// Run on every change with the new ``revision`` (Settings > Keys' event stream).
    @ObservationIgnored private var watchers: [UInt64: (Int) -> Void] = [:]
    @ObservationIgnored private var nextWatcher: UInt64 = 0
    /// A request was added (its banner posts) / ended (its banner goes).
    @ObservationIgnored package var onAdded: ((Request) -> Void)?
    @ObservationIgnored package var onEnded: ((String) -> Void)?

    package init() {}

    /// A fresh request id (`kr_…`).
    package nonisolated static func newID() -> String {
        "kr_" + UUID().uuidString.prefix(12).lowercased()
    }

    /// The waiting requests, oldest first.
    package var requests: [Request] {
        _ = revision
        return waiting.map(\.request)
    }

    package func request(_ id: String) -> Request? {
        _ = revision
        return waiting.first { $0.request.id == id }?.request
    }

    /// Adds a request; `end` runs once, on the main actor, when it ends. Answers its id.
    @discardableResult
    package func add(id: String = KeyRequests.newID(), name: String, purpose: String, hosts: [String], ttl: String?, requester: String,
                     at date: Date = Date(), end: @escaping (Outcome) -> Void) -> String {
        if let early = endedEarly.firstIndex(of: id) {
            endedEarly.remove(at: early)
            end(.cancelled)
            return id
        }
        // Same name: the newer ask wins; the older one's agent hears cancelled.
        let replaced = waiting.filter { $0.request.name == name }
        waiting.removeAll { $0.request.name == name }
        var dropped: [(request: Request, end: (Outcome) -> Void)] = []
        while waiting.count >= Self.limit, let oldest = waiting.first {
            dropped.append(oldest)
            waiting.removeFirst()
        }
        let request = Request(id: id, name: name, purpose: purpose, hosts: hosts, ttl: ttl, requester: requester, askedAt: date)
        waiting.append((request, end))
        changed()
        onAdded?(request)
        for old in replaced + dropped {
            onEnded?(old.request.id)
            old.end(.cancelled)
        }
        return id
    }

    /// Ends request `id` with `outcome`; false when it no longer waits (ended already).
    @discardableResult
    package func finish(_ id: String, _ outcome: Outcome) -> Bool {
        guard let index = waiting.firstIndex(where: { $0.request.id == id }) else { return false }
        let ended = waiting.remove(at: index)
        changed()
        onEnded?(id)
        ended.end(outcome)
        return true
    }

    /// The asker of `id` stopped waiting: it ends as cancelled, now or, when its ask is not added
    /// yet, as soon as it is.
    package func abandon(_ id: String) {
        guard !finish(id, .cancelled) else { return }
        endedEarly.append(id)
        if endedEarly.count > Self.limit { endedEarly.removeFirst() }
    }

    /// Adds `ask` as request `id` and waits for its end. A cancel of the calling task (the request's
    /// deadline) or ``abandon(_:)`` (the asker's connection closed) ends it as cancelled.
    package func ask(_ ask: KeyRequestParams, id: String = KeyRequests.newID()) async -> Outcome {
        let abandon: @MainActor @Sendable () -> Void = { [weak self] in self?.abandon(id) }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Outcome, Never>) in
                guard !Task.isCancelled else { return continuation.resume(returning: .cancelled) }
                add(id: id, name: ask.name, purpose: ask.purpose, hosts: ask.hosts, ttl: ask.ttl, requester: ask.requester) { outcome in
                    continuation.resume(returning: outcome)
                }
            }
        } onCancel: {
            MainDelivery().run(abandon)
        }
    }

    /// Runs `onChange` with the new revision after every change until the answer's `cancel` runs.
    package func watch(_ onChange: @escaping (Int) -> Void) -> () -> Void {
        nextWatcher += 1
        let key = nextWatcher
        watchers[key] = onChange
        return { [weak self] in self?.watchers[key] = nil }
    }

    private func changed() {
        revision += 1
        for watcher in watchers.values { watcher(revision) }
    }
}

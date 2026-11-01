public import Foundation
public import CmuxNextCompat

/// The confirm and write order of a page's switches that widen what another machine may do on this Mac
/// (Settings' Full access and Dedicated agent machine). The page's provider checks the person's click
/// first; this owns what comes after it, per switch and machine (`key`).
///
/// SECURITY: an on asks `confirm` (Touch ID or the login password) every time and turns on only when it
/// succeeds. A cancel, a failure, no confirm (a Mac that cannot ask), or a second ask while one is up
/// leaves it off. An off only narrows, so it asks nothing, and it wins over every on asked before it: an
/// on still in its confirm, or queued behind another write, is dropped. Writes for one key run one at a
/// time in the order they were asked, so they land in that order.
@MainActor public final class PageWideningGate {
    /// Offs per key: an on asked under an older count is dropped.
    public private(set) var offs: [String: Int] = [:]
    /// The tail of each key's write chain, which the next write for that key waits on.
    public private(set) var writes: [String: Task<Void, Never>] = [:]
    /// A turn-on confirm is up: a second one asks nothing and is refused.
    private var confirming = false
    private var claimedGestures: Set<TimeInterval> = []

    public nonisolated init() {}

    /// Claims one person-backed page gesture process-wide, so two Settings windows cannot reuse it.
    public func claimGesture(_ event: TimeInterval) -> Bool {
        claimedGestures.insert(event).inserted
    }

    public final class WritePermit: Sendable {
        private let state = Mutex<(valid: Bool, claimed: Bool)>((true, false))

        /// Atomically claims the write slot. Cancellation that wins before this returns prevents the
        /// host call; cancellation after it returns cannot pretend that an already-started host call did
        /// not happen.
        nonisolated func claim() -> Bool {
            state.withLock { state in
                guard state.valid, !state.claimed else { return false }
                state.claimed = true
                return true
            }
        }

        nonisolated func invalidate() {
            state.withLock { $0.valid = false }
        }
    }

    /// Turns `key` on or off through `write` (the host's error, or nil); throws `refusal` for an on that
    /// is not confirmed or that an off overtook.
    public func set(_ key: String, on: Bool, confirm: (@MainActor () async -> Bool)?, refusal: PageError,
                    write: @escaping @MainActor (Bool, WritePermit) async -> String?) async throws -> String? {
        if on {
            guard !confirming, let confirm else { throw refusal }
            let offsBefore = offs[key, default: 0]
            confirming = true
            let confirmed = await confirm()
            confirming = false
            guard !Task.isCancelled, confirmed, offs[key, default: 0] == offsBefore else { throw refusal }
            return try await queued(key, on: true, after: offsBefore, refusal: refusal, write)
        }
        offs[key, default: 0] += 1
        return try await queued(key, on: false, after: offs[key, default: 0], refusal: refusal, write)
    }

    /// Queues a write whose host performs its own authentication (Join consent). The same cancellation-
    /// safe permit and per-key ordering as ``set`` apply, without asking a second confirmation here.
    public func setWithoutConfirmation(
        _ key: String, on: Bool, refusal: PageError,
        write: @escaping @MainActor (Bool) async -> String?
    ) async throws -> String? {
        let after: Int
        if on {
            after = offs[key, default: 0]
        } else {
            offs[key, default: 0] += 1
            after = offs[key, default: 0]
        }
        return try await queued(key, on: on, after: after, refusal: refusal) { value, _ in
            await write(value)
        }
    }

    /// Runs one write for `key` after the ones asked before it. An on runs only if no off came in after
    /// it was asked (`after` is the off count it was asked under); otherwise it is refused.
    private func queued(_ key: String, on: Bool, after offsAsked: Int, refusal: PageError,
                        _ write: @escaping @MainActor (Bool, WritePermit) async -> String?) async throws -> String? {
        let previous = writes[key]
        let permit = WritePermit()
        // task-owner: one link of the write chain for one key; ends with its host write.
        let task = Task { @MainActor [weak self] () -> String?? in
            await previous?.value
            guard !Task.isCancelled, let self else { return .none }
            if on, self.offs[key, default: 0] != offsAsked { return .none }
            guard !Task.isCancelled, permit.claim() else { return .none }
            return .some(await write(on, permit))
        }
        // task-owner: the chain's tail, which the next write for this key waits on; ends with `task`.
        writes[key] = Task { _ = await task.value }
        return try await withTaskCancellationHandler(operation: {
            guard let answer = await task.value else { throw refusal }
            return answer
        }, onCancel: {
            permit.invalidate()
            task.cancel()
        })
    }
}

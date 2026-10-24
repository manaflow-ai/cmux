import Foundation

/// What a ``SavedFrameDirectory`` knows of its frames: the listing, each frame's phase, the one pane
/// waiting for it, and the order the reader decodes in. Held under the directory's lock for short
/// moves only: nothing here reads a file or decodes an image.
struct SavedFrameDirectoryState: Sendable {
    /// Receives a frame decoded after its pane asked for it, on the main actor.
    typealias Waiter = @MainActor @Sendable (SavedFrame) -> Void

    /// Where one listed frame is.
    enum Phase: Sendable {
        /// Listed, not decoded yet.
        case pending
        /// The reader decodes it now.
        case decoding
        /// Decoded, not asked for yet; nil when the file could not be read or decoded.
        case done(SavedFrame?)
        /// Handed to its pane (at once or by its waiter), or dropped by a release.
        case taken
    }

    /// One listed frame file.
    struct Entry: Sendable {
        var file: URL
        var scale: Int
        var phase = Phase.pending
    }

    /// What one look at a key found for its taker.
    enum Claim: Sendable {
        /// Decoded: the frame, handed over now.
        case frame(SavedFrame)
        /// Not decoded yet: the waiter gets it once the reader decoded it.
        case waiting
        /// Nothing to hand over: no such file, a failed decode, already handed out, or released.
        case none
    }

    /// The frames by tab key, once listed.
    var entries: [String: Entry]?
    /// The pane waiting for each frame not decoded yet: at most one per key (a frame is handed out once).
    var waiters: [String: Waiter] = [:]
    /// The listed keys the reader has not claimed yet, in the order it decodes them.
    var queue: [String] = []
    /// The keys the launch's first windows show (``SavedFrameDirectory/prioritize(_:)``).
    var wanted: [String] = []
    /// Keys a pane asked for before they were decoded: decoded before every other.
    var asked: [String] = []
    var released = false
    /// The reader is inside a decode (between ``claimNext()`` and ``decoded(_:_:)``).
    var decodingNow = false
    /// Tests waiting for the reader to have nothing left to do.
    var idleWaiters: [CheckedContinuation<Void, Never>] = []

    /// Whether the reader has nothing left to do: listed, no decode running and none queued.
    var isIdle: Bool { entries != nil && queue.isEmpty && !decodingNow }

    /// Records the listing: each key pending, in the order ``ordered(_:)`` gives. A waiter whose
    /// key has no file is dropped: its pane draws without a last frame.
    mutating func listed(_ found: [String: Entry]) {
        guard entries == nil else { return }
        entries = released ? [:] : found
        waiters = waiters.filter { found[$0.key] != nil && !released }
        queue = ordered(Array((entries ?? [:]).keys).sorted())
    }

    /// Decodes `keys` (front window first) before the rest, after the keys a pane asked for.
    mutating func prioritize(_ keys: [String]) {
        wanted = keys
        queue = ordered(queue)
    }

    /// Hands `key`'s frame over, or keeps `waiter` for it when it is not decoded yet (and moves it
    /// to the front of the reader's queue).
    mutating func claim(_ key: String, waiter: @escaping Waiter) -> Claim {
        guard !released else { return .none }
        guard var entry = entries?[key] else {
            // Not listed yet: wait for the listing, which drops the waiter when there is no file.
            guard entries == nil, waiters[key] == nil else { return .none }
            waiters[key] = waiter
            ask(key)
            return .waiting
        }
        switch entry.phase {
        case .done(let frame):
            entry.phase = .taken
            entries?[key] = entry
            return frame.map(Claim.frame) ?? .none
        case .taken:
            return .none
        case .pending, .decoding:
            guard waiters[key] == nil else { return .none }
            waiters[key] = waiter
            ask(key)
            return .waiting
        }
    }

    /// The next key for the reader, marked as being decoded; nil when none is left.
    mutating func claimNext() -> (key: String, entry: Entry)? {
        guard !released else { return nil }
        while !queue.isEmpty {
            let key = queue.removeFirst()
            guard var entry = entries?[key], case .pending = entry.phase else { continue }
            entry.phase = .decoding
            entries?[key] = entry
            decodingNow = true
            return (key, entry)
        }
        return nil
    }

    /// The reader decoded `key` into `frame`: the waiting pane's delivery, if one waits for it.
    /// After a ``release()`` the entry is gone, so nothing is kept or delivered.
    mutating func decoded(_ key: String, _ frame: SavedFrame?) -> (Waiter, SavedFrame)? {
        decodingNow = false
        guard var entry = entries?[key], case .decoding = entry.phase else { return nil }
        guard let waiter = waiters.removeValue(forKey: key) else {
            entry.phase = .done(frame)
            entries?[key] = entry
            return nil
        }
        entry.phase = .taken
        entries?[key] = entry
        return frame.map { (waiter, $0) }
    }

    /// Drops every frame and waiter: later takes find nothing, the reader starts no other decode.
    mutating func release() {
        released = true
        entries = entries.map { _ in [:] }
        waiters = [:]
        queue = []
    }

    /// Takes the continuations waiting for the reader to be idle, when it is.
    mutating func takeIdleWaiters() -> [CheckedContinuation<Void, Never>] {
        guard isIdle else { return [] }
        defer { idleWaiters = [] }
        return idleWaiters
    }

    /// Puts `key` first among the asked keys and reorders the queue.
    private mutating func ask(_ key: String) {
        asked.removeAll { $0 == key }
        asked.insert(key, at: 0)
        queue = ordered(queue)
    }

    /// `keys` with the asked ones first (latest ask first), then the ``wanted`` ones in their order,
    /// then the rest in theirs.
    private func ordered(_ keys: [String]) -> [String] {
        let present = Set(keys)
        var first: [String] = []
        var seen: Set<String> = []
        for key in asked + wanted where present.contains(key) && seen.insert(key).inserted { first.append(key) }
        return first + keys.filter { !seen.contains($0) }
    }
}

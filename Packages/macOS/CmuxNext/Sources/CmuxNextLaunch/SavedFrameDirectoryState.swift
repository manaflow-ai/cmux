import Foundation

/// What a ``SavedFrameDirectory`` knows of its frames: the listing, each frame's phase, and the
/// order the background decodes go in. Held under the directory's lock for short moves only:
/// nothing here reads a file or decodes an image.
struct SavedFrameDirectoryState {
    /// Where one listed frame is.
    enum Phase {
        /// Listed, not decoded yet.
        case pending
        /// A background lane decodes it now (``SavedFrameDirectory`` lane index).
        case decoding(lane: Int)
        /// Decoded; nil when the file could not be read or decoded.
        case done(SavedFrame?)
        /// Handed out (or claimed by a taker that decodes it), or dropped by a release.
        case taken
    }

    /// One listed frame file.
    struct Entry {
        var file: URL
        var scale: Int
        var phase = Phase.pending
    }

    /// The frames by tab key, once listed.
    var entries: [String: Entry]?
    /// The listed keys no lane has claimed yet, in the order the lanes take them.
    var queue: [String] = []
    /// The keys the launch's first window shows, decoded before the rest (``prioritize(_:)``).
    var wanted: [String] = []
    var released = false

    /// Records the listing: each key pending, the ``wanted`` keys first in the queue.
    mutating func listed(_ found: [String: Entry]) {
        guard entries == nil else { return }
        entries = released ? [:] : found
        queue = ordered(Array((entries ?? [:]).keys).sorted())
    }

    /// Puts `keys` first in the queue (those not claimed yet), in their order.
    mutating func prioritize(_ keys: [String]) {
        wanted = keys
        queue = ordered(queue)
    }

    /// The next pending key for `lane`, marked as its decode; nil when none is left.
    mutating func claimNext(lane: Int) -> (key: String, entry: Entry)? {
        guard !released else { return nil }
        while !queue.isEmpty {
            let key = queue.removeFirst()
            guard var entry = entries?[key], case .pending = entry.phase else { continue }
            entry.phase = .decoding(lane: lane)
            entries?[key] = entry
            return (key, entry)
        }
        return nil
    }

    /// A lane's decode of `key` ended with `frame`.
    mutating func decoded(_ key: String, _ frame: SavedFrame?) {
        guard var entry = entries?[key], case .decoding = entry.phase else { return }
        entry.phase = released ? .taken : .done(frame)
        entries?[key] = entry
    }

    /// Drops every frame: later takes find nothing, and no lane starts another decode.
    mutating func release() {
        released = true
        entries = entries.map { _ in [:] }
        queue = []
    }

    /// `keys` with the ``wanted`` ones first (in their order), the rest after in theirs.
    private func ordered(_ keys: [String]) -> [String] {
        let present = Set(keys)
        let first = wanted.filter(present.contains)
        let firstSet = Set(first)
        return first + keys.filter { !firstSet.contains($0) }
    }
}

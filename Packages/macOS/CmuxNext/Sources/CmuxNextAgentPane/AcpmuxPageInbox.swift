/// The frames queued for the page (``AcpmuxPaneSocket/State/inbox``): appended at the back, taken
/// from the front a flush at a time. A plain `Array` paid `removeFirst(count)` per flush, which moves
/// every frame still queued: a page 32,768 frames behind (the ceiling) drained in 64-frame flushes
/// moved about 8 M strings under the socket's lock, on the main actor. Here a take moves a head
/// index; the dead prefix is dropped once it is half the storage, so each frame moves at most once
/// (amortized O(1) per frame, O(k) per take of k).
nonisolated struct AcpmuxPageInbox: Sendable {
    private var storage: [String] = []
    private var head = 0

    var count: Int { storage.count - head }
    var isEmpty: Bool { head == storage.count }

    /// The frame `offset` places from the front.
    subscript(offset: Int) -> String { storage[head + offset] }

    mutating func append(_ frame: String) { storage.append(frame) }

    mutating func append(contentsOf frames: [String]) { storage.append(contentsOf: frames) }

    /// Removes and returns the first `k` frames (clamped to `0...count`).
    mutating func removeFirst(_ requested: Int) -> [String] {
        let k = min(max(requested, 0), count)
        let taken = Array(storage[head..<(head + k)])
        head += k
        if head == storage.count {
            storage.removeAll(keepingCapacity: true)
            head = 0
        } else if head >= 1024, head * 2 >= storage.count {
            storage.removeSubrange(0..<head)
            head = 0
        }
        return taken
    }

    mutating func removeAll() {
        storage.removeAll()
        head = 0
    }
}

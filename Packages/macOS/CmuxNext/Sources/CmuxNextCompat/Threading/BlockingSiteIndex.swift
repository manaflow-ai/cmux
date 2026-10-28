#if DEBUG || CMUX_BLOCKING_CHECKS
/// The call sites the main thread has seen, by ``BlockingSiteKey``: a fixed open-addressing table
/// (twice the site limit, so a probe stays short) that never allocates after its init. Main
/// thread only.
struct BlockingSiteIndex {
    private var keys: [BlockingSiteKey]
    private var ids: [Int]
    private let limit: Int
    private(set) var count = 0

    /// An index of at most `capacity` sites.
    init(capacity: Int) {
        limit = capacity
        keys = Array(repeating: .empty, count: capacity * 2)
        ids = Array(repeating: -1, count: capacity * 2)
    }

    /// The site id of `key`, if it was seen.
    func find(_ key: BlockingSiteKey) -> Int? {
        var slot = Self.start(key, keys.count)
        while keys[slot] != .empty {
            if keys[slot] == key { return ids[slot] }
            slot = (slot + 1) % keys.count
        }
        return nil
    }

    /// The id the next new site gets, or nil when the index is full.
    var nextID: Int? { count < limit ? count : nil }

    /// Adds `key` (not seen before; ``nextID`` was not nil) under the id ``nextID`` named.
    mutating func insert(_ key: BlockingSiteKey) {
        guard count < limit, key != .empty else { return }
        var slot = Self.start(key, keys.count)
        while keys[slot] != .empty { slot = (slot + 1) % keys.count }
        keys[slot] = key
        ids[slot] = count
        count += 1
    }

    private static func start(_ key: BlockingSiteKey, _ size: Int) -> Int {
        Int(UInt(bitPattern: key.hash) % UInt(size))
    }
}
#endif

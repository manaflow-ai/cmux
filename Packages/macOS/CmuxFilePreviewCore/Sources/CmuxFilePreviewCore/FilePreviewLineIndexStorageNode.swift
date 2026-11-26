/// One block node in ``FilePreviewLineIndexStorage``'s implicit treap.
/// `offsets` stores packed line-break offsets (separator kind in low bits).
struct FilePreviewLineIndexStorageNode: Sendable {
    var offsets: [Int]
    var priority: UInt64
    var left: Int?
    var right: Int?
    var size: Int
    var lazyDelta: Int

    init(offsets: [Int], priority: UInt64) {
        self.offsets = offsets
        self.priority = priority
        left = nil
        right = nil
        size = offsets.count
        lazyDelta = 0
    }
}

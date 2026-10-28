import Foundation

/// Pauses a sidecar directory operation on its dedicated I/O queue. The test
/// controls the filesystem boundary without sleeps or blocking Swift executors.
final class WorkstreamClearFileManager: FileManager, @unchecked Sendable {
    private let condition = NSCondition()
    private var remaining = 0
    private var permits = 0
    let entries: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    override init() {
        (entries, continuation) = AsyncStream<Void>.makeStream()
        super.init()
    }

    func arm(count: Int = 1) {
        condition.lock()
        remaining = count
        condition.unlock()
    }

    func release() {
        condition.lock()
        permits += 1
        condition.broadcast()
        condition.unlock()
    }

    override func createDirectory(
        at url: URL,
        withIntermediateDirectories createIntermediates: Bool,
        attributes: [FileAttributeKey: Any]? = nil
    ) throws {
        condition.lock()
        if remaining > 0 {
            remaining -= 1
            continuation.yield(())
            while permits == 0 { condition.wait() }
            permits -= 1
        }
        condition.unlock()
        try super.createDirectory(at: url, withIntermediateDirectories: createIntermediates, attributes: attributes)
    }
}

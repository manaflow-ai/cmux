import Foundation

/// Pauses a sidecar directory operation on its dedicated I/O queue. The test
/// controls the filesystem boundary without sleeps or blocking Swift executors.
final class WorkstreamClearFileManager: FileManager, @unchecked Sendable {
    private let condition = NSCondition()
    private var armed = false
    private var released = false
    let entries: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    override init() {
        (entries, continuation) = AsyncStream<Void>.makeStream()
        super.init()
    }

    func arm() {
        condition.lock()
        armed = true
        condition.unlock()
    }

    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }

    override func createDirectory(
        at url: URL,
        withIntermediateDirectories createIntermediates: Bool,
        attributes: [FileAttributeKey: Any]? = nil
    ) throws {
        condition.lock()
        if armed {
            armed = false
            continuation.yield(())
            while !released { condition.wait() }
        }
        condition.unlock()
        try super.createDirectory(at: url, withIntermediateDirectories: createIntermediates, attributes: attributes)
    }
}

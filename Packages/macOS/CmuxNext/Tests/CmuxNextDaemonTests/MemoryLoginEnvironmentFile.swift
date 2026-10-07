import Foundation
import Synchronization
@testable import CmuxNextDaemon

/// An in-memory `LoginEnvironmentStore` file whose writes a test can await.
final class MemoryLoginEnvironmentFile: Sendable {
    private let contents: Mutex<Data?>
    private let writes: AsyncStream<Void>
    private let writeContinuation: AsyncStream<Void>.Continuation

    init(remembering environment: [String: String]? = nil) {
        let record = environment.map { LoginEnvironmentStore.Record(version: LoginEnvironmentStore.version, environment: $0) }
        contents = Mutex(record.flatMap { try? JSONEncoder().encode($0) })
        let (writes, writeContinuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingOldest(8))
        self.writes = writes
        self.writeContinuation = writeContinuation
    }

    var store: LoginEnvironmentStore {
        LoginEnvironmentStore(read: { self.contents.withLock { $0 } }, write: { data in
            self.contents.withLock { $0 = data }
            self.writeContinuation.yield()
        })
    }

    var text: String { contents.withLock { $0.map { String(decoding: $0, as: UTF8.self) } } ?? "" }

    /// Waits for the next write after the ones already seen.
    func nextWrite() async { for await _ in writes { return } }
}

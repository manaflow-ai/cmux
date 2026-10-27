import CmuxNextCompat
@testable import CmuxNextServerHelper
import Foundation
import Testing

/// The privileged helper's prior-value store reads and writes its file only inside the items it gives its files
/// lane, never on the caller's thread and never under a lock (plans/cmux-next/chrome-parity/p02-threads.md, task 036).
@Suite(.timeLimit(.minutes(1))) struct ServerFixPriorStoreTests {
    /// A files lane that holds each item until the test releases it, then runs it on its own queue. After an item's
    /// body and before the store's `await` returns, it notes what the file holds and runs `afterEachItem`, so a test
    /// sees what the item itself did to the file, apart from what the store did before or after it.
    nonisolated final class HeldFiles: ServerFixPriorFiles {
        let arrivals: AsyncStream<Void>
        private let arrived: AsyncStream<Void>.Continuation
        private let file: ServerFixPriorFile
        private let afterEachItem: @Sendable () -> Void
        private let queue = DispatchQueue(label: "test.server-helper.held-files")
        private let state = Mutex((held: [@Sendable () -> Void](), seen: [[String: Int]]()))

        init(url: URL, afterEachItem: @escaping @Sendable () -> Void = {}) {
            (arrivals, arrived) = AsyncStream<Void>.makeStream()
            file = ServerFixPriorFile(url: url)
            self.afterEachItem = afterEachItem
        }

        /// What the file held at the end of each item that ran, in order.
        var seen: [[String: Int]] { state.withLock { $0.seen } }

        func run<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
            try await withCheckedThrowingContinuation { continuation in
                let item: @Sendable () -> Void = { [self] in
                    let result = Result { try body() }
                    let onDisk = file.load()
                    state.withLock { $0.seen.append(onDisk) }
                    afterEachItem()
                    continuation.resume(with: result)
                }
                state.withLock { $0.held.append(item) }
                arrived.yield()
            }
        }

        /// Runs every held item on the lane's queue, in the order they came.
        func release() {
            let items = state.withLock { state in
                defer { state.held.removeAll() }
                return state.held
            }
            for item in items { queue.async(execute: item) }
        }
    }

    /// A store file in a folder of its own that the store creates (0700, as the helper's).
    func storeURL() -> (root: URL, url: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("server-fix-priors-\(UUID().uuidString)", isDirectory: true)
        return (root, root.appendingPathComponent("store", isDirectory: true).appendingPathComponent("helper.json"))
    }

    @Test func recordWritesTheFileInsideTheLaneItem() async throws {
        let (root, url) = storeURL()
        defer { try? FileManager.default.removeItem(at: root) }
        let files = HeldFiles(url: url)
        let store = FileFixPriorStore(url: url, files: files)
        var arrivals = files.arrivals.makeAsyncIterator()

        let recording = Task { try await store.record(.systemSleepOffOnAC, prior: 10) }
        _ = await arrivals.next()
        // The store waits on its lane item and wrote nothing on the caller's thread before it.
        #expect(!FileManager.default.fileExists(atPath: url.path))

        files.release()
        try await recording.value
        // The value was on disk when the item ended, before the store's await returned: the item wrote it.
        #expect(files.seen == [[ServerFix.systemSleepOffOnAC.rawValue: 10]])
    }

    @Test func priorReadsTheFileInsideTheLaneItem() async throws {
        let (root, url) = storeURL()
        defer { try? FileManager.default.removeItem(at: root) }
        let key = ServerFix.systemSleepOffOnAC.rawValue
        let file = ServerFixPriorFile(url: url)
        try file.save([key: 10])
        // After the item the file changes again: a read after the lane would see 30.
        let files = HeldFiles(url: url) { _ = try? file.save([key: 30]) }
        let store = FileFixPriorStore(url: url, files: files)
        var arrivals = files.arrivals.makeAsyncIterator()

        let reading = Task { await store.prior(.systemSleepOffOnAC) }
        _ = await arrivals.next()
        // A read on the caller's thread before the lane would have seen 10.
        try file.save([key: 20])

        files.release()
        #expect(await reading.value == 20)
    }

    @Test func clearRemovesTheValueInsideTheLaneItem() async throws {
        let (root, url) = storeURL()
        defer { try? FileManager.default.removeItem(at: root) }
        let key = ServerFix.systemSleepOffOnAC.rawValue
        let other = ServerFix.diskSleepOffOnAC.rawValue
        try ServerFixPriorFile(url: url).save([key: 10, other: 5])
        let files = HeldFiles(url: url)
        let store = FileFixPriorStore(url: url, files: files)
        var arrivals = files.arrivals.makeAsyncIterator()

        let clearing = Task { try await store.clear(.systemSleepOffOnAC) }
        _ = await arrivals.next()
        #expect(ServerFixPriorFile(url: url).load() == [key: 10, other: 5])

        files.release()
        try await clearing.value
        #expect(files.seen == [[other: 5]])
    }

    @Test func recordKeepsTheFirstValueOnDiskUntilCleared() async throws {
        let (root, url) = storeURL()
        defer { try? FileManager.default.removeItem(at: root) }
        let lane = ServerHelperFileLane()
        let store = FileFixPriorStore(url: url, files: lane)

        try await store.record(.systemSleepOffOnAC, prior: 10)
        try await store.record(.systemSleepOffOnAC, prior: 0)
        // A new store (the helper relaunched) reads the value the first record kept.
        let reopened = FileFixPriorStore(url: url, files: lane)
        #expect(await reopened.prior(.systemSleepOffOnAC) == 10)
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)

        try await reopened.clear(.systemSleepOffOnAC)
        #expect(await store.prior(.systemSleepOffOnAC) == nil)
    }

    @Test func memoryStoreKeepsTheFirstValue() {
        let store = MemoryFixPriorStore()
        store.record(.systemSleepOffOnAC, prior: 10)
        store.record(.systemSleepOffOnAC, prior: 0)
        #expect(store.prior(.systemSleepOffOnAC) == 10)
        store.clear(.systemSleepOffOnAC)
        #expect(store.prior(.systemSleepOffOnAC) == nil)
    }
}

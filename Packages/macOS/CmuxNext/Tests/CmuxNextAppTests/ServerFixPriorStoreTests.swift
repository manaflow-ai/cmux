import CmuxNextCompat
@testable import CmuxNextServerHelper
import Foundation
import Testing

/// The privileged helper's prior-value store reads and writes its file only on the files lane it is given,
/// never on the caller's thread and never under a lock (plans/cmux-next/chrome-parity/p02-threads.md, task 036).
@Suite(.timeLimit(.minutes(1))) struct ServerFixPriorStoreTests {
    /// The helper's own lane, counting its files-lane items and the threads they ran on.
    nonisolated final class CountingLane: MayBlockRunner {
        let lane = ServerHelperFileLane(label: "test.server-helper.files")
        private let state = Mutex((items: 0, onMain: 0))

        var items: Int { state.withLock { $0.items } }
        var onMain: Int { state.withLock { $0.onMain } }

        func runFiles<T: Sendable>(_ priority: MayBlockPriority, shutdown: MayBlockShutdown, site: MayBlockCallSite,
                                   _ body: @escaping @Sendable () throws -> T) async throws -> T {
            state.withLock { $0.items += 1 }
            return try await lane.runFiles(priority, shutdown: shutdown, site: site) { [self] in
                if Thread.isMainThread { state.withLock { $0.onMain += 1 } }
                return try body()
            }
        }

        func runSystem<T: Sendable>(_ priority: MayBlockPriority, shutdown: MayBlockShutdown, site: MayBlockCallSite,
                                    _ body: @escaping @Sendable () throws -> T) async throws -> T {
            Issue.record("the store has no system-lane work")
            return try await lane.runSystem(priority, shutdown: shutdown, site: site, body)
        }

        func runHostResolution<T: Sendable>(_ priority: MayBlockPriority, shutdown: MayBlockShutdown, site: MayBlockCallSite,
                                            _ body: @escaping @Sendable () throws -> T) async throws -> T {
            Issue.record("the store resolves no host")
            return try await lane.runHostResolution(priority, shutdown: shutdown, site: site, body)
        }

        func postFiles(_ priority: MayBlockPriority, shutdown: MayBlockShutdown, site: MayBlockCallSite,
                       _ body: @escaping @Sendable () -> Void) {
            state.withLock { $0.items += 1 }
            lane.postFiles(priority, shutdown: shutdown, site: site, body)
        }
    }

    /// A store file in a folder of its own that the store creates (0700, as the helper's).
    func storeURL() -> (root: URL, url: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("server-fix-priors-\(UUID().uuidString)", isDirectory: true)
        return (root, root.appendingPathComponent("store", isDirectory: true).appendingPathComponent("helper.json"))
    }

    @Test func everyReadAndWriteRunsOnTheFilesLane() async throws {
        let (root, url) = storeURL()
        defer { try? FileManager.default.removeItem(at: root) }
        let lane = CountingLane()
        let store = FileFixPriorStore(url: url, files: lane)

        #expect(await store.prior(.systemSleepOffOnAC) == nil)
        try await store.record(.systemSleepOffOnAC, prior: 10)
        try await store.clear(.systemSleepOffOnAC)

        #expect(lane.items == 3)
        #expect(lane.onMain == 0)
    }

    @Test func recordKeepsTheFirstValueOnDiskUntilCleared() async throws {
        let (root, url) = storeURL()
        defer { try? FileManager.default.removeItem(at: root) }
        let lane = ServerHelperFileLane(label: "test.server-helper.files")
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

    @MainActor @Test func theFileLaneRunsItsItemsOffTheMainThread() async throws {
        let lane = ServerHelperFileLane(label: "test.server-helper.files")
        let ranOnMain = try await lane.runFiles(.userVisible) { Thread.isMainThread }
        #expect(ranOnMain == false)
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

import CmuxNextCloud
@testable import CmuxNextCompat
import CmuxNextWakeups
import Foundation
import Testing

/// This Mac's install id (`CloudDeviceID`, `CloudPaths.loadOrCreateDeviceID`): the first read makes the Cloud
/// folders and the id file off the main thread (blocking probe 2026-10-24: `CloudPaths.prepare`, 2.3 ms on the
/// main thread at launch), and first reads at the same time agree on one id.
@Suite
struct CloudDeviceIDTests {
    #if DEBUG
    /// A main-actor caller's first read creates the folders and the file on the files lane: the blocking
    /// detector records nothing on the main thread.
    @MainActor @Test func theFirstReadMakesTheFolderAndFileOffTheMainThread() async throws {
        let root = Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CloudDeviceID(paths: CloudPaths(root: root), work: BackgroundWork())
        let table = BlockingViolationTable(mode: .record)

        let id = try await BlockingViolationTable.$scoped.withValue(table) { try await store.load() }
        await table.flush()

        #expect(BlockingDetector(table: table).sites.isEmpty)
        #expect(id.hasPrefix("mac-"))
        #expect(store.cached == id)
        #expect(try store.loadNow() == id)
        #expect(try CloudPaths(root: root).loadOrCreateDeviceID() == id)
    }

    /// The read that Cloud's start begins is the one a later caller gets: one id, kept.
    @MainActor @Test func aPreloadThenALoadReturnTheSameKeptID() async throws {
        let root = Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CloudDeviceID(paths: CloudPaths(root: root), work: BackgroundWork())

        store.preload()
        let id = try await store.load()

        #expect(store.cached == id)
        #expect(try CloudPaths(root: root).loadOrCreateDeviceID() == id)
    }
    #endif

    /// First reads at the same time (the launch read, a synchronous caller, the tunnel hub) return one id: the
    /// first file written wins and none replaces it.
    @Test func concurrentFirstReadsAgreeOnOneID() async throws {
        let root = Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = CloudPaths(root: root)

        let ids = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<8 { group.addTask { try paths.loadOrCreateDeviceID() } }
            var ids = Set<String>()
            for try await id in group { ids.insert(id) }
            return ids
        }

        #expect(ids.count == 1)
        #expect(try paths.loadOrCreateDeviceID() == ids.first)
        let left = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasSuffix(".tmp") }
        #expect(left.isEmpty)
    }

    private static func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("cloud-device-id-\(UUID().uuidString)", isDirectory: true)
    }
}

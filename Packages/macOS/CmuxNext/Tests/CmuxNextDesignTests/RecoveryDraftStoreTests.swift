@testable import CmuxNextDesign
import Darwin
import Foundation
import Testing

/// The recovery-draft backstop (R96 quit hook): written on edit after a
/// debounce on the injected clock, crash-safe and private (0700 / 0600,
/// not backed up), bounded in size, never brought back after a removal.
@MainActor
struct RecoveryDraftStoreTests {
    static func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("drafts-\(UUID().uuidString)", isDirectory: true)
    }

    /// The debounced write runs after a main-actor hop; wait for it (bounded).
    static func settle(_ store: RecoveryDraftStore, count: Int) async -> [RecoveryDraft] {
        var drafts = await store.drafts()
        for _ in 0..<500 where drafts.count != count {
            await Task.yield()
            drafts = await store.drafts()
        }
        return drafts
    }

    @Test func anEditIsWrittenAfterTheDebounce() async {
        let clock = ManualClock()
        let store = RecoveryDraftStore(directory: Self.directory(), clock: clock)
        #expect(store.update(id: "file:local:/a", title: "a", contents: Data("hello".utf8)) == .kept)
        #expect(await store.drafts().isEmpty, "nothing before the debounce")
        await clock.sleepers(atLeast: 1)
        clock.advance(by: .seconds(1))
        let drafts = await Self.settle(store, count: 1)
        #expect(drafts.map(\.contents) == [Data("hello".utf8)])
        #expect(drafts.first?.host == "local")
    }

    /// A normal save removes the draft; an update still waiting for its
    /// debounce must not bring it back.
    @Test func removeBeforeTheDebounceLeavesNoDraft() async {
        let clock = ManualClock()
        let store = RecoveryDraftStore(directory: Self.directory(), clock: clock)
        store.update(id: "file:local:/a", title: "a", contents: Data("x".utf8))
        await store.remove(id: "file:local:/a")
        clock.advance(by: .seconds(5))
        for _ in 0..<50 { await Task.yield() }
        #expect(await store.drafts().isEmpty)
    }

    @Test func aDraftOverTheLimitIsNotKept() async {
        let store = RecoveryDraftStore(directory: Self.directory(), clock: ManualClock(), maxDraftBytes: 4)
        #expect(store.update(id: "file:local:/big", title: "big", contents: Data("12345".utf8)) == .tooLarge)
        await store.writePending()
        #expect(await store.drafts().isEmpty)
    }

    @Test func overTheTotalCapTheOldestDraftGoes() async {
        let store = RecoveryDraftStore(directory: Self.directory(), clock: ManualClock(), maxTotalBytes: 600)
        store.update(id: "file:local:/old", title: "old", contents: Data(repeating: 65, count: 200))
        await store.writePending()
        store.update(id: "file:local:/new", title: "new", contents: Data(repeating: 66, count: 200))
        await store.writePending()
        #expect(await store.drafts().map(\.title) == ["new"])
    }

    @Test func draftsArePrivateAndNotBackedUp() async throws {
        let directory = Self.directory()
        let store = RecoveryDraftStore(directory: directory, clock: ManualClock())
        store.update(id: "file:local:/a", title: "a", contents: Data("secret".utf8))
        await store.writePending()
        let dirMode = try #require(try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber)
        #expect(dirMode.intValue & 0o777 == 0o700)
        let file = try #require(try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
        let fileMode = try #require(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)
        #expect(fileMode.intValue & 0o777 == 0o600)
        #expect(try directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
    }

    @Test func theSamePathOnTwoHostsKeepsTwoDrafts() async {
        let store = RecoveryDraftStore(directory: Self.directory(), clock: ManualClock())
        store.update(id: "file:local:/a", title: "a", contents: Data("l".utf8))
        store.update(id: "file:cloud1:/a", title: "a", contents: Data("c".utf8), host: "cloud1")
        await store.writePending()
        #expect(Set(await store.drafts().map(\.host)) == ["local", "cloud1"])
    }

    @Test func aFileThatChangedSinceTheDraftIsReported() async throws {
        let directory = Self.directory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("notes.md")
        try "v1".write(to: file, atomically: true, encoding: .utf8)
        let store = RecoveryDraftStore(directory: directory.appendingPathComponent("recovery"), clock: ManualClock())
        store.update(id: "file:local:\(file.path)", title: "notes.md", contents: Data("draft".utf8), filePath: file.path)
        await store.writePending()
        let draft = try #require(await store.drafts().first)
        #expect(await store.fileChangedSince(draft) == false)
        try "version two".write(to: file, atomically: true, encoding: .utf8)
        #expect(await store.fileChangedSince(draft))
    }
}

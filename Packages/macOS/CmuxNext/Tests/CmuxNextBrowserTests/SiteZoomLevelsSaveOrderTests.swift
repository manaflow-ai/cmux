import CmuxNextBrowser
import CmuxNextWakeups
import Foundation
import Testing

/// A zoom set before a profile's file was read must not write a file with only that host: the save waits for
/// the read, and the first write holds the stored hosts and the new one (p08-startup-098).
@MainActor @Suite(.timeLimit(.minutes(1))) struct SiteZoomLevelsSaveOrderTests {
    @Test func aSetBeforeTheReadKeepsEveryStoredHostOnDisk() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("site-zoom-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let profile = BrowserProfileID(rawValue: UUID())
        let file = directory.appending(path: profile.rawValue.uuidString + ".json")
        try JSONEncoder().encode(["a.example": 1.5, "b.example": 2.0]).write(to: file)

        let work = BackgroundWork(label: "test.site-zoom")
        let files = work.sequence("test.siteZoom")
        let levels = SiteZoomLevels(directory: directory, offTheRecord: OffTheRecordProfiles(), files: files)
        levels.set(1.25, host: "c.example", profile: profile)  // before any read of the file
        await levels.load(profile)
        try await files.run(.userVisible) {}  // after every write posted so far

        let reloaded = SiteZoomLevels(directory: directory, offTheRecord: OffTheRecordProfiles(), files: files)
        await reloaded.load(profile)
        #expect(reloaded.level(host: "a.example", profile: profile) == 1.5)
        #expect(reloaded.level(host: "b.example", profile: profile) == 2.0)
        #expect(reloaded.level(host: "c.example", profile: profile) == 1.25)
    }

    /// Quit right after a set: whether the read ran or shutdown dropped it, the file keeps its stored hosts.
    @Test func shutdownBeforeTheReadNeverReplacesTheFile() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("site-zoom-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let profile = BrowserProfileID(rawValue: UUID())
        let file = directory.appending(path: profile.rawValue.uuidString + ".json")
        try JSONEncoder().encode(["a.example": 1.5, "b.example": 2.0]).write(to: file)

        let work = BackgroundWork(label: "test.site-zoom")
        let files = work.sequence("test.siteZoom")
        let levels = SiteZoomLevels(directory: directory, offTheRecord: OffTheRecordProfiles(), files: files)
        levels.set(1.25, host: "c.example", profile: profile)
        await work.shutdown()

        let stored = try JSONDecoder().decode([String: Double].self, from: Data(contentsOf: file))
        #expect(stored["a.example"] == 1.5)
        #expect(stored["b.example"] == 2.0)
    }

    @Test func aSetAfterTheReadWritesAtOnce() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("site-zoom-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let profile = BrowserProfileID(rawValue: UUID())

        let files = BackgroundWork(label: "test.site-zoom").sequence("test.siteZoom")
        let levels = SiteZoomLevels(directory: directory, offTheRecord: OffTheRecordProfiles(), files: files)
        await levels.load(profile)  // no file yet
        levels.set(0.75, host: "a.example", profile: profile)
        levels.set(1.1, host: "b.example", profile: profile)
        try await files.run(.userVisible) {}

        let reloaded = SiteZoomLevels(directory: directory, offTheRecord: OffTheRecordProfiles(), files: files)
        await reloaded.load(profile)
        #expect(reloaded.level(host: "a.example", profile: profile) == 0.75)
        #expect(reloaded.level(host: "b.example", profile: profile) == 1.1)
    }
}

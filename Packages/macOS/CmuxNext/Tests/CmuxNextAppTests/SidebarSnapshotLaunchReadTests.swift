@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextWakeups
import Foundation
import Testing

/// `SidebarSnapshotStore.init` read and decoded `sidebar-snapshot-v1.json` on the main thread inside
/// `AppServices.init`. The file is now read on a launch lane from `main`; the store takes that read, and a change
/// made before it ends is applied on the saved document, so the next write never drops the last run's windows.
@Suite("Sidebar snapshot read on a launch lane", .serialized)
@MainActor
struct SidebarSnapshotLaunchReadTests {
    private static func folder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "sidebar-snapshot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private static func snapshot(_ active: String) -> SidebarSnapshot {
        SidebarSnapshot(sections: [SidebarSnapshot.Section](), profiles: [SidebarSnapshot.Profile](), activeProfileID: active)
    }

    /// A file with window `w1` saved, as the last run left it.
    private static func savedFile(in folder: URL) throws -> SidebarSnapshotFile {
        let file = SidebarSnapshotFile(url: folder.appending(path: SidebarSnapshotFile.fileName))
        var document = SidebarSnapshotDocument()
        document.record(snapshot("saved"), window: "w1")
        try file.write(document)
        return file
    }

    @Test("The store is made with no read on the main thread, and draws the saved sidebar once the lane read it")
    func theStoreTakesTheLaneRead() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = try Self.savedFile(in: folder)
        let probe = LaunchReadProbe(held: true)
        let read = file.startLaunchRead(on: BackgroundWork(label: "test.sidebar-snapshot"), reader: probe.reader)
        #expect(await probe.waitForStart(), "the launch read never started")
        let store = SidebarSnapshotStore(file: file, saved: read)
        #expect(store.launchDocument.windows.isEmpty, "while the read runs the first frame gets no rows, and no wait")
        probe.release()
        _ = await read.finished()
        #expect(store.launchDocument.snapshot(for: "w1", fallback: false)?.activeProfileID == "saved")
        #expect(probe.reads == [false], "the file was read once, off the main thread")
    }

    /// Before the change the store's document was the read at init. Now a record can come before the read ends: it
    /// must apply on top of the saved windows, not replace them with a document holding only itself.
    @Test("A change made while the read runs keeps the saved windows in the next write", .timeLimit(.minutes(1)))
    func aChangeBeforeTheReadKeepsTheSavedWindows() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = try Self.savedFile(in: folder)
        let probe = LaunchReadProbe(held: true)
        let read = file.startLaunchRead(on: BackgroundWork(label: "test.sidebar-snapshot-early"), reader: probe.reader)
        #expect(await probe.waitForStart(), "the launch read never started")
        let store = SidebarSnapshotStore(file: file, saved: read, debounce: .seconds(60))
        await store.record(Self.snapshot("new"), window: "w2", sequence: 1)
        probe.release()
        await store.flush()
        let written = try #require(SidebarSnapshotFile(url: file.url).read())
        #expect(written.windows.map(\.windowID) == ["w2", "w1"])
        #expect(await store.writeCount == 1)
    }

    @Test("A missing file reads as an empty document")
    func aMissingFileIsEmpty() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = SidebarSnapshotFile(url: folder.appending(path: SidebarSnapshotFile.fileName))
        let read = file.startLaunchRead(on: BackgroundWork(label: "test.sidebar-snapshot-missing"))
        #expect(await read.finished().windows.isEmpty)
        let store = SidebarSnapshotStore(file: file, saved: read)
        await store.flush()
        #expect(await store.writeCount == 0, "nothing changed, nothing written")
    }
}

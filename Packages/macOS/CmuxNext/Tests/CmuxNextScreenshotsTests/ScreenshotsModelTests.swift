import CmuxNextFileGrid
@testable import CmuxNextScreenshots
import Foundation
import Testing

/// The pane's live model: merged listing, watch events, filters and the drop folder.
@Suite(.serialized) struct ScreenshotsModelTests {
    static func source(_ id: String, _ folder: URL, origin: ScreenshotSourceOrigin = .system,
                       rule: FileGridScanRule = FileGridScanRule()) -> ScreenshotSource {
        ScreenshotSource(id: id, label: id, folder: folder, origin: origin, rule: rule)
    }

    /// No watch: these tests drive events by hand, so the order is deterministic.
    static func model() -> ScreenshotsModel {
        ScreenshotsModel(watcher: SilentWatcher())
    }

    @Test func mergesEveryFolderNewestFirst() async throws {
        let first = try TemporaryFolder()
        let second = try TemporaryFolder()
        try first.write("old.png", modified: Date(timeIntervalSince1970: 10))
        try second.write("new.mov", modified: Date(timeIntervalSince1970: 30))
        try first.write("mid.png", modified: Date(timeIntervalSince1970: 20))
        let model = Self.model()
        defer { model.stop() }
        model.setSources([Self.source("a", first.url), Self.source("b", second.url)])
        await model.refresh()
        #expect(model.visibleItems.map(\.name) == ["new.mov", "mid.png", "old.png"])
        model.selectedSourceID = "a"
        #expect(model.visibleItems.map(\.name) == ["mid.png", "old.png"])
        model.query = "MID"
        #expect(model.visibleItems.map(\.name) == ["mid.png"])
    }

    @Test func aNewFileEventAddsItAndADeleteEventRemovesIt() async throws {
        let folder = try TemporaryFolder()
        let model = Self.model()
        defer { model.stop() }
        model.setSources([Self.source("a", folder.url)])
        await model.refresh()
        #expect(model.visibleItems.isEmpty)
        let shot = try folder.write("Screenshot.png")
        await model.apply([DirectoryWatcherEvent(path: shot.path)])
        #expect(model.visibleItems.map(\.name) == ["Screenshot.png"])
        try FileManager.default.removeItem(at: shot)
        await model.apply([DirectoryWatcherEvent(path: shot.path)])
        #expect(model.visibleItems.isEmpty)
    }

    /// A rename is two events (old and new path): the old name leaves, the new one shows.
    @Test func aRenameMovesTheItem() async throws {
        let folder = try TemporaryFolder()
        let old = try folder.write("a.png")
        let model = Self.model()
        defer { model.stop() }
        model.setSources([Self.source("a", folder.url)])
        await model.refresh()
        let new = folder.url.appendingPathComponent("b.png")
        try FileManager.default.moveItem(at: old, to: new)
        await model.apply([DirectoryWatcherEvent(path: old.path), DirectoryWatcherEvent(path: new.path)])
        #expect(model.visibleItems.map(\.name) == ["b.png"])
    }

    /// The preview folder appears per screenshot (NSIRD_screencaptureui_*): a folder event relists.
    @Test func aNewPreviewFolderRelistsItsSource() async throws {
        let temp = try TemporaryFolder()
        let rule = FileGridScanRule(depth: 1, folderPrefix: "NSIRD_screencaptureui_")
        let model = Self.model()
        defer { model.stop() }
        model.setSources([Self.source("p", temp.url, origin: .systemPreview, rule: rule)])
        await model.refresh()
        let shot = try temp.write("NSIRD_screencaptureui_x1/Screenshot.png")
        await model.apply([DirectoryWatcherEvent(path: shot.deletingLastPathComponent().path, isDirectory: true)])
        await model.refresh()
        #expect(model.visibleItems.map(\.name) == ["Screenshot.png"])
    }

    @Test func eventsOutsideTheRuleAreIgnored() throws {
        let folder = URL(fileURLWithPath: "/s", isDirectory: true)
        let preview = Self.source("p", folder, rule: FileGridScanRule(depth: 1, folderPrefix: "NSIRD_"))
        #expect(ScreenshotsModel.isListed("/s/top.png", in: preview))
        #expect(ScreenshotsModel.isListed("/s/NSIRD_1/a.png", in: preview))
        #expect(!ScreenshotsModel.isListed("/s/Other/a.png", in: preview))
        #expect(!ScreenshotsModel.isListed("/s/NSIRD_1/deep/a.png", in: preview))
        #expect(!ScreenshotsModel.isListed("/elsewhere/a.png", in: preview))
    }

    @Test func removingASourceDropsItsFilesAndItsSelection() async throws {
        let first = try TemporaryFolder()
        let second = try TemporaryFolder()
        try first.write("a.png")
        try second.write("b.png")
        let model = Self.model()
        defer { model.stop() }
        model.setSources([Self.source("a", first.url), Self.source("b", second.url)])
        await model.refresh()
        model.selectedSourceID = "b"
        model.setSources([Self.source("a", first.url)])
        #expect(model.selectedSourceID == nil)
        #expect(model.visibleItems.map(\.name) == ["a.png"])
    }

    @Test func dropsGoToTheSelectedFolderWhenItTakesThemElseTheMacOSFolder() throws {
        let model = Self.model()
        defer { model.stop() }
        let system = URL(fileURLWithPath: "/sys", isDirectory: true)
        let history = URL(fileURLWithPath: "/hist", isDirectory: true)
        let mine = URL(fileURLWithPath: "/mine", isDirectory: true)
        model.setSources([
            Self.source("system", system), Self.source("h", history, origin: .toolHistory(.cleanShotX)), Self.source("m", mine, origin: .custom),
        ])
        #expect(model.dropDestination == system)
        model.selectedSourceID = "h"
        #expect(model.dropDestination == system)
        model.selectedSourceID = "m"
        #expect(model.dropDestination == mine)
    }

    @Test func anUnreadableFolderIsReported() async {
        let model = Self.model()
        defer { model.stop() }
        model.setSources([Self.source("gone", URL(fileURLWithPath: "/nowhere/\(UUID().uuidString)", isDirectory: true))])
        await model.refresh()
        #expect(model.unreadableSourceIDs == ["gone"])
    }

    /// The real watch: a screenshot saved into a watched folder shows without any relist.
    @Test(.timeLimit(.minutes(1))) func theWatchShowsANewScreenshot() async throws {
        let folder = try TemporaryFolder()
        let model = ScreenshotsModel(watcher: DirectoryWatcher(latency: 0.05))
        defer { model.stop() }
        model.setSources([Self.source("a", folder.url)])
        await model.refresh()
        try folder.write("Screenshot live.png")
        // Each pass waits for the model's next change (no polling); the watch is the only writer.
        while !model.visibleItems.contains(where: { $0.name == "Screenshot live.png" }) {
            await withCheckedContinuation { continuation in
                withObservationTracking { _ = model.visibleItems } onChange: { continuation.resume() }
            }
        }
        #expect(model.visibleItems.map(\.name) == ["Screenshot live.png"])
    }
}

/// Reports nothing: the tests apply events themselves.
nonisolated struct SilentWatcher: DirectoryWatching {
    func events(for paths: [String]) -> AsyncStream<[DirectoryWatcherEvent]> {
        AsyncStream { $0.finish() }
    }
}

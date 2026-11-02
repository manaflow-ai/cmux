import AppKit
import CmuxNextFileGrid
import CmuxNextFiles
@testable import CmuxNextScreenshots
import Foundation
import os
import Testing

/// The pane's live model: merged listing, watch events, filters and the drop folder.
@Suite(.serialized) struct ScreenshotsModelTests {
    static func source(_ id: String, _ folder: URL, origin: ScreenshotSourceOrigin = .system,
                       rule: ScreenshotScanRule = ScreenshotScanRule()) -> ScreenshotSource {
        ScreenshotSource(id: id, label: id, folder: folder, origin: origin, rule: rule)
    }

    /// No watch: these tests drive events by hand, so the order is deterministic.
    static func model() -> ScreenshotsModel {
        ScreenshotsModel(watcher: SilentWatcher(), listsAtOnce: true)
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
        await model.apply(.items(["Screenshot.png"]), in: folder.url)
        #expect(model.visibleItems.map(\.name) == ["Screenshot.png"])
        try FileManager.default.removeItem(at: shot)
        await model.apply(.items(["Screenshot.png"]), in: folder.url)
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
        await model.apply(.items(["a.png", "b.png"]), in: folder.url)
        #expect(model.visibleItems.map(\.name) == ["b.png"])
    }

    /// The preview folder appears per screenshot (NSIRD_screencaptureui_*): a new folder relists
    /// the source and is watched from then on; a file changed inside it is looked at alone.
    @Test func aNewPreviewFolderRelistsItsSourceAndIsWatched() async throws {
        let temp = try TemporaryFolder()
        let rule = ScreenshotScanRule(depth: 1, folderPrefix: "NSIRD_screencaptureui_")
        let model = Self.model()
        defer { model.stop() }
        model.setSources([Self.source("p", temp.url, origin: .systemPreview, rule: rule)])
        await model.refresh()
        #expect(model.watchedFolders == [temp.url.path])
        let shot = try temp.write("NSIRD_screencaptureui_x1/Screenshot.png")
        let preview = shot.deletingLastPathComponent()
        await model.apply(.items(["NSIRD_screencaptureui_x1"]), in: temp.url)
        await model.refresh()
        #expect(model.visibleItems.map(\.name) == ["Screenshot.png"])
        #expect(model.watchedFolders == [temp.url.path, preview.path])
        try temp.write("NSIRD_screencaptureui_x1/Second.png")
        await model.apply(.items(["Second.png"]), in: preview)
        #expect(Set(model.visibleItems.map(\.name)) == ["Screenshot.png", "Second.png"])
    }

    /// Lost events (a dropped FSEvents batch) list the folder again.
    @Test func aRescanRelistsTheSource() async throws {
        let folder = try TemporaryFolder()
        let model = Self.model()
        defer { model.stop() }
        model.setSources([Self.source("a", folder.url)])
        await model.refresh()
        try folder.write("missed.png")
        await model.apply(.rescan, in: folder.url)
        await model.refresh()
        #expect(model.visibleItems.map(\.name) == ["missed.png"])
    }

    @Test func eventsOutsideTheRuleAreIgnored() throws {
        let folder = URL(fileURLWithPath: "/s", isDirectory: true)
        let preview = Self.source("p", folder, rule: ScreenshotScanRule(depth: 1, folderPrefix: "NSIRD_"))
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

    /// The real watch (CmuxNextFiles' FolderWatcher): a screenshot saved into a watched folder shows.
    @Test(.timeLimit(.minutes(1))) func theWatchShowsANewScreenshot() async throws {
        let folder = try TemporaryFolder()
        let model = ScreenshotsModel(watcher: FolderWatcher(latency: 0.05), listsAtOnce: true)
        defer { model.stop() }
        model.setSources([Self.source("a", folder.url)])
        await model.refresh()
        // FolderWatcher schedules its FSEvents stream asynchronously, so a write right after the
        // read can come before it: keep writing (as FileHelpersTests does) until one shows.
        let writer = Task.detached {
            var n = 0
            while !Task.isCancelled {
                _ = try? folder.write("Screenshot live \(n).png")
                n += 1
                // A bounded, cancelled pause between writes (the real signal is the model change below).
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        defer { writer.cancel() }
        // Each pass waits for the model's next change (no polling); the watch is the only writer.
        while !model.visibleItems.contains(where: { $0.name.hasPrefix("Screenshot live") }) {
            await withCheckedContinuation { continuation in
                withObservationTracking { _ = model.visibleItems } onChange: { continuation.resume() }
            }
        }
        writer.cancel()
        // The writer holds the folder: wait for it to end, so the folder is removed before the test
        // returns rather than whenever the detached task last runs (never, if the process exits first).
        await writer.value
        #expect(model.visibleItems.allSatisfy { $0.name.hasPrefix("Screenshot live") })
    }
}

/// Reports nothing: the tests apply events themselves.
nonisolated struct SilentWatcher: FolderWatching {
    func changes(in folder: URL) -> AsyncStream<FolderChange> {
        AsyncStream { $0.finish() }
    }
}

/// ~/Desktop is macOS's default screenshot folder, which macOS guards. The app's page model is made with
/// `listsAtOnce: false`: a page an agent or a script made off screen reads and watches no folder until it is on
/// screen (`startListing()`).
@MainActor @Suite struct ScreenshotsModelListsOnlyWhenStartedTests {
    @Test func aModelNotStartedReadsAndWatchesNoFolder() async {
        let lister = RecordingLister()
        let watcher = RecordingWatcher()
        let model = ScreenshotsModel(reader: ScreenshotFolderReader(lister: lister), watcher: watcher, listsAtOnce: false)
        let desktop = URL(fileURLWithPath: "/Users/someone/Desktop", isDirectory: true)
        model.setSources([ScreenshotsModelTests.source("system", desktop)])
        await model.refresh()
        #expect(!model.isListing)
        #expect(await lister.listed.isEmpty)
        #expect(watcher.watched.isEmpty)

        model.startListing()
        await model.refresh()
        #expect(model.isListing)
        #expect(await lister.listed.contains(desktop.path))
        #expect(watcher.watched.contains(desktop.path))
    }
}

/// Records each folder the model lists.
private actor RecordingLister: DirectoryListing {
    private(set) var listed: [String] = []
    func list(_ folder: URL) async throws -> [FileEntry] {
        listed.append(folder.path)
        return []
    }
    func entry(at url: URL) async -> FileEntry? { nil }
}

/// Records each folder the model watches; reports no change.
private final class RecordingWatcher: FolderWatching {
    private let paths = OSAllocatedUnfairLock(initialState: [String]())
    var watched: [String] { paths.withLock { $0 } }
    func changes(in folder: URL) -> AsyncStream<FolderChange> {
        paths.withLock { $0.append(folder.path) }
        return AsyncStream { $0.finish() }
    }
}

/// The decision of a `screenshots.open` run: only the person's own run brings the tab to the front; any other run
/// opens it in the background and says so, even when it asked for focus.
@Suite struct ScreenshotsOpenDecisionTests {
    @Test func onlyThePersonsRunSelectsAndEveryOtherRunIsTold() {
        let person = ScreenshotsOpen(personsRun: true)
        #expect(person.selects && person.note == nil)
        let script = ScreenshotsOpen(personsRun: false)
        #expect(!script.selects)
        #expect(script.note?.isEmpty == false)
        // What a script hears: a new tab opened behind, or the tab already there, listing or waiting for the click.
        #expect(person.result(existing: false, listing: false) == nil)
        let opened = script.result(existing: false, listing: false)
        #expect(opened?.opened == "background" && opened?.listing == false && opened?.note != nil)
        let listing = script.result(existing: true, listing: true)
        #expect(listing?.opened == "existing" && listing?.listing == true && listing?.note == nil)
        let waiting = script.result(existing: true, listing: false)
        #expect(waiting?.opened == "existing" && waiting?.listing == false && waiting?.note != nil)
    }
}

/// The gate remembers the person's click by tab key, so a page made again (hibernation wake, engine switch)
/// lists with no second click, and no folder is detected until the first click.
@MainActor @Suite struct ScreenshotsGateTests {
    @Test func nothingIsUnlockedOrDetectedBeforeTheClickAndTheClickIsRememberedPerTab() {
        let gate = ScreenshotsGate()
        #expect(!gate.mayDetect)
        #expect(!gate.isUnlocked("tab-a"))
        gate.unlock("tab-a")
        #expect(gate.mayDetect)
        #expect(gate.isUnlocked("tab-a"))
        #expect(!gate.isUnlocked("tab-b"))
    }

    /// A plain NSButton takes the keyboard only with Full Keyboard Access on, so the pane itself takes it while the
    /// prompt is up, and Space (the button's key) shows the screenshots; then the grid has the keyboard again.
    @MainActor @Test func spacePressesShowScreenshotsWhileThePromptIsUp() throws {
        let model = ScreenshotsModel(watcher: SilentWatcher(), listsAtOnce: false)
        let view = ScreenshotsView(model: model, cache: ThumbnailCache(), workspace: NoWorkspace())
        // Plain values in each expectation: a failure message must not reflect the view (its drop pasteboard).
        let paneTakesKeys = view.focusTarget === view
        #expect(paneTakesKeys, "the pane does not take the keyboard before the click")
        let acceptsKeys = view.acceptsFirstResponder
        #expect(acceptsKeys)
        let space = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                                  context: nil, characters: " ", charactersIgnoringModifiers: " ",
                                                  isARepeat: false, keyCode: 49))
        view.keyDown(with: space)
        let listing = model.isListing
        #expect(listing, "Space did not show the screenshots")
        let gridTakesKeys = view.focusTarget !== view
        #expect(gridTakesKeys)
    }

    @Test func aModelListsOnlyWhenItsCallerSaysSo() {
        #expect(!ScreenshotsModel(watcher: SilentWatcher()).isListing, "the default must be the safe one")
    }
}

@MainActor private final class NoWorkspace: ScreenshotsWorkspace {
    func open(_ urls: [URL]) {}
    func reveal(_ urls: [URL]) {}
}

import AppKit
import CmuxNextDesign
import CmuxNextFileGrid
import CmuxNextFiles
@testable import CmuxNextScreenshots
import CmuxNextWakeups
import Foundation
import Testing

/// The Screenshots pane's part of the History, Feed, Cloud, Server and Screenshots sweep
/// (plans/cmux-next/chrome-parity/p06-scheduler.md, rule 9): a folder's read runs off the
/// main actor and lands as a posted task on the app's scheduler, and the pane's grid follows the model only while
/// it shows (a hidden pane reads no model change and refreshes once on show).
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct ScreenshotsSchedulerSweepTests {
    /// A folder's read lands through the scheduler, not as a main-inherited Task resume: the listing appears once
    /// a posted turn ran.
    @Test func aFolderReadLandsAsAPostedTask() async throws {
        let folder = try TemporaryFolder()
        _ = try folder.write("Screenshot 1.png")
        let turns = QueuedTurns()
        let model = ScreenshotsModel(watcher: SilentWatcher(), mainWork: screenshotsTestWork(turns: turns))
        defer { model.stop() }
        model.setSources([ScreenshotsModelTests.source("a", folder.url)])
        #expect(model.visibleItems.isEmpty, "the read landed inline")
        await model.refresh()
        #expect(model.visibleItems.map(\.name) == ["Screenshot 1.png"])
        #expect(turns.count >= 1, "the read landed with no posted task")
    }

    /// The grid, the count and the source menu read the model only while the pane shows: changes while it is
    /// hidden refresh nothing, and its show refreshes once.
    @Test func aHiddenPaneRefreshesOnceOnShow() async throws {
        _ = NSApplication.shared
        let work = screenshotsTestWork()
        let model = ScreenshotsModel(watcher: SilentWatcher(), mainWork: work)
        let view = ScreenshotsView(model: model, cache: ThumbnailCache(), workspace: RecordingWorkspace(),
                                   files: FileOperator(work: BackgroundWork(label: "test.screenshots")), mainWork: work)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 320), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        // The window's node reads visible (the window is never ordered in), so the pane's node follows only its own hide.
        _ = WindowVisibilitySource.of(window, read: { _ in .visible })
        window.contentView = view
        defer { window.contentView = nil; window.close(); model.stop() }
        try await Self.settle { view.refreshes > 0 }

        view.isHidden = true
        let hidden = view.refreshes
        model.query = "a"
        model.query = "ab"
        model.selectedSourceID = "x"
        for _ in 0..<50 { await Task.yield() }
        #expect(view.refreshes == hidden, "a hidden pane refreshed \(view.refreshes - hidden) times")

        view.isHidden = false
        try await Self.settle { view.refreshes > hidden }
        for _ in 0..<50 { await Task.yield() }
        #expect(view.refreshes == hidden + 1, "the show refreshed \(view.refreshes - hidden) times (want 1)")
    }

    private static func settle(_ done: () -> Bool) async throws {
        for _ in 0..<10_000 where !done() { await Task.yield() }
        try #require(done())
    }
}

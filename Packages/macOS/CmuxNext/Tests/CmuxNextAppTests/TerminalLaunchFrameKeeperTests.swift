import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextTerminal
import CmuxNextTestSupport
import CmuxNextWakeups
import Testing

/// REOPEN-F6 (reopen film, 2026-11-02): after a kill (crash, force quit, power loss) no visible terminal had a saved
/// frame, because frames were saved only in the quit path; every pane was empty until live content, 566-730 ms after
/// main(). While the app runs, each visible terminal's frame is kept on disk (coalesced, off the main thread), in the
/// files the next launch reads, so a launch after a kill shows it in its first window frame too.
@MainActor @Suite(.serialized, .closesItsWindows) struct TerminalLaunchFrameKeeperTests {
    static let work = BackgroundWork(label: "test.terminal-launch-frame-keeper")

    /// A shown terminal with drawn content in a window.
    @MainActor struct Shown {
        let window: NSWindow
        let io = ScriptedTerminalIO()
        let session: TerminalSession
        /// The suite runner's windows are occluded (no screen): Ghostty draws there only with this on.
        let drew = WindowDrawPolicy.drawsWhenOccluded

        init() async throws {
            _ = NSApplication.shared
            WindowDrawPolicy.drawsWhenOccluded = true
            session = TerminalSession(io: io)
            window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 480, height: 240), styleMask: [.borderless],
                              backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = session.view
            window.orderFrontRegardless()
            session.view.layoutSubtreeIfNeeded()
            try #require(session.surfaceView.surface != nil, "libghostty created no surface")
            io.send(.output(Data("kept frame\r\n".utf8)))
            let drawnBy = ContinuousClock.now.advanced(by: .seconds(10))
            while ContinuousClock.now < drawnBy, session.surfaceView.presentedFrame == nil || !session.surfaceHasContent {
                try await Task.sleep(for: .milliseconds(20)) // test: the first frame draws
            }
            try #require(session.surfaceView.presentedFrame != nil, "the terminal never drew")
        }

        func close() {
            WindowDrawPolicy.drawsWhenOccluded = drew
            io.finish()
            window.close()
        }
    }

    /// The key's saved frames in `directory` (never an atomic write's file before its rename).
    static func files(_ key: String, in directory: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).filter { TerminalLaunchFrames.owner(of: $0) == key }.sorted()
    }

    /// Waits until `condition` holds or `seconds` pass; the keeper's files lane writes asynchronously.
    static func eventually(_ seconds: Double = 10, _ condition: () -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try await Task.sleep(for: .milliseconds(25)) // test: the files lane writes
        }
        return condition()
    }

    @Test func aShownTerminalsFrameIsOnDiskWithNoQuitAndTheNextLaunchShowsIt() async throws {
        let shown = try await Shown()
        defer { shown.close() }
        let state = FileManager.default.temporaryDirectory.appending(path: "keeper-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: state) }
        let directory = state.appending(path: "terminal-launch-frames", directoryHint: .isDirectory)
        let frames = TerminalLaunchFrames(directory: directory)
        // The app shows the terminal: it is kept from now on. No quit path runs (a kill ends the app here).
        frames.keep("tab_kept", session: shown.session, work: Self.work)
        let written = try await Self.eventually { !Self.files("tab_kept", in: directory).isEmpty }
        #expect(written, "no frame on disk while the app runs: a kill now leaves the next launch nothing to show")

        // The next launch reads it like a quit's frame and shows it over the new session.
        let next = TerminalLaunchFrames(directory: directory)
        await next.prefetch(on: Self.work)?.value
        let reveal = LaunchReveal(deadline: .seconds(60))
        // A pane of the terminal host's size: its surface fills the host (the terminal's scroller is an overlay one
        // even where the system shows legacy scroll bars, a mini with no trackpad), the size the frame was kept at.
        let content = NSView(frame: NSRect(origin: .zero, size: shown.session.view.bounds.size))
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: 200, y: 200), size: content.frame.size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = content
        reveal.hold(content, until: .pane)
        #expect(next.showAhead("tab_kept", in: content, reveal: reveal), "the kept frame did not show at the next launch")
    }

    @Test func aHiddenTerminalLosesItsKeptFrame() async throws {
        let shown = try await Shown()
        defer { shown.close() }
        let directory = FileManager.default.temporaryDirectory.appending(path: "keeper-hidden-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let frames = TerminalLaunchFrames(directory: directory)
        frames.keep("tab_hidden", session: shown.session, work: Self.work)
        try #require(try await Self.eventually { !Self.files("tab_hidden", in: directory).isEmpty }, "the shown frame was never kept")
        // The terminal goes out of view (its workspace switched away): it is not on screen at a kill, so no frame.
        shown.session.isRenderingSuspended = true
        let gone = try await Self.eventually { Self.files("tab_hidden", in: directory).isEmpty }
        #expect(gone, "a hidden terminal's frame stays: the next launch would show it in a pane that shows another terminal")
    }

    /// Issue #32274: the keeper drops the files of terminals this run does not show once the launch read has ended, by
    /// the terminals it keeps. A pane that still shows its saved frame ahead of its surface (no session yet, so not
    /// kept) is on screen too: the keeper removed its frame, and a quit or a kill then left that pane empty at the next
    /// launch.
    @Test func aPaneShownAheadOfItsSurfaceKeepsItsFrameWhileOtherTerminalsAreKept() async throws {
        let shown = try await Shown()
        defer { shown.close() }
        let reveal = LaunchReveal(deadline: .seconds(60))
        let waiting = TerminalLaunchFrameTests.WaitingPane(reveal: reveal)
        defer { waiting.window.close() }
        waiting.window.orderFrontRegardless()
        let directory = try await TerminalLaunchFrameTests.saved(
            ["tab_ahead": TerminalLaunchFrameTests.frame(waiting.surfaceSize, scale: waiting.window.backingScaleFactor)])
        defer { try? FileManager.default.removeItem(at: directory) }
        let frames = TerminalLaunchFrames(directory: directory)
        await frames.prefetch(on: Self.work)?.value
        try #require(frames.showAhead("tab_ahead", in: waiting.content, reveal: reveal))
        // Another terminal on screen is kept: its write drops the files of terminals this run does not show.
        frames.keep("tab_kept", session: shown.session, work: Self.work)
        try #require(try await Self.eventually { !Self.files("tab_kept", in: directory).isEmpty }, "the shown frame was never kept")
        // The same files-lane job drops the other files right after that write: give it time to.
        let removed = try await Self.eventually(1) { Self.files("tab_ahead", in: directory).isEmpty }
        #expect(!removed, "the keeper removed the frame of a pane still showing it ahead of its surface: the next launch shows it empty")
    }

    /// The keeper test flake (2 of 10 on feat): Foundation's atomic write puts the bytes in a file beside the target
    /// (`tab_kept@1x.jpg.sb-<id>`) and renames it after. Code that took every `<key>@...` name for a saved frame read
    /// too early (the test) or removed another writer's file before its rename (the keeper's cleanup: a quit that saves
    /// beside a late keeper write then lost that terminal's frame). Only `<key>@<scale>x.jpg` is a saved frame.
    @Test func aKeeperWriteLeavesAnotherWritesFileInProgressAlone() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "keeper-in-progress-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        // Another write (the quit's, of a terminal this keeper does not keep) has its bytes down and not renamed yet.
        let inProgress = directory.appending(path: "tab_quit@2x.jpg.sb-3ccdeb25-8UvLgh")
        try Data("jpeg".utf8).write(to: inProgress)
        let frame = try #require(TerminalLaunchFrameTests.frame(NSSize(width: 4, height: 4), scale: 1)
            .cgImage(forProposedRect: nil, context: nil, hints: nil))
        TerminalLaunchFrames.writeOne(frame, key: "tab_kept", scale: 1, to: directory, keeping: ["tab_kept"])
        #expect(FileManager.default.fileExists(atPath: inProgress.path),
                "the keeper removed another write's file before its rename: that terminal's frame is lost")
        #expect(Self.files("tab_quit", in: directory).isEmpty, "a file in progress counted as a saved frame")
    }

    /// Review of #32372 (P3): a keeper write that started before the quit stopped the keeper must not land over the
    /// quit's frames nor prune them: it checks again before it writes and before it cleans up.
    @Test func aKeeperWriteThatTheQuitStoppedWritesAndRemovesNothing() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "keeper-stopped-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let quitFrame = directory.appending(path: "tab_quit@1x.jpg")
        try Data("quit".utf8).write(to: quitFrame)
        let frame = try #require(TerminalLaunchFrameTests.frame(NSSize(width: 4, height: 4), scale: 1)
            .cgImage(forProposedRect: nil, context: nil, hints: nil))
        TerminalLaunchFrames.writeOne(frame, key: "tab_kept", scale: 1, to: directory, keeping: ["tab_kept"], stillWanted: { false })
        #expect(FileManager.default.fileExists(atPath: quitFrame.path), "a stopped keeper write pruned the quit's frame")
        #expect(Self.files("tab_kept", in: directory).isEmpty, "a stopped keeper write landed after the quit")
    }

    /// Never per keystroke: a terminal that changes constantly (an echo per key, a busy program) is saved at most once
    /// per interval.
    @Test func aBusyTerminalIsSavedAtMostOncePerInterval() async throws {
        let shown = try await Shown()
        defer { shown.close() }
        let directory = FileManager.default.temporaryDirectory.appending(path: "keeper-busy-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let frames = TerminalLaunchFrames(directory: directory)
        frames.keep("tab_busy", session: shown.session, work: Self.work)
        try #require(try await Self.eventually { !Self.files("tab_busy", in: directory).isEmpty }, "the first frame was never kept")
        let saves = frames.keepSaves
        // 3 s of keystroke-rate output (every 30 ms: up to 100 changes, fewer on a loaded runner).
        let end = ContinuousClock.now.advanced(by: .seconds(3))
        var keys = 0
        while ContinuousClock.now < end {
            shown.io.send(.output(Data("x".utf8)))
            keys += 1
            try await Task.sleep(for: .milliseconds(30)) // test: keystroke rate
        }
        let extra = frames.keepSaves - saves
        #expect(keys >= 20, "only \(keys) changes in 3 s: the test did not keep the terminal busy") // a loaded runner sleeps longer
        #expect(extra <= 1, "\(extra) saves for \(keys) changes in 3 s: the keeper saves per change, not once per 5 s")
        // No starvation: a terminal that never goes quiet is still saved again within interval + busy wait.
        let busyUntil = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < busyUntil {
            shown.io.send(.output(Data("y".utf8)))
            try await Task.sleep(for: .milliseconds(30)) // test: keystroke rate
        }
        let again = try await Self.eventually(3) { frames.keepSaves > saves + extra }
        #expect(again, "a terminal that keeps changing was never saved again: its kept frame grows stale without bound")
    }

    /// REOPEN VIDEO on build d77b7cfc (6 of 30 kill cycles): a split resized a terminal after its frame was saved, the
    /// 5 s interval blocked a new save, and the kill 3-4 s later left a frame of the old size (refused at launch) or
    /// none. A resize saves again as soon as the terminal is quiet, with no interval.
    @Test
    func aResizedTerminalIsSavedAgainWithoutWaitingForTheInterval() async throws {
        // Review of #35470 (T5): in both states of `motion.frameOwner.terminals` (off, the default until cmux-ad m19: the surface takes
        // its new size in the layout; on: in the commit that shows its frame, a refresh or two later).
        let shown = try await Shown()
        defer { shown.close() }
        let directory = FileManager.default.temporaryDirectory.appending(path: "keeper-resize-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let frames = TerminalLaunchFrames(directory: directory)
        frames.keep("tab_resized", session: shown.session, work: Self.work)
        try #require(try await Self.eventually { !Self.files("tab_resized", in: directory).isEmpty }, "the first frame was never kept")
        let saves = frames.keepSaves
        // The pane halves (Cmd-D beside it): the surface view gets a new size, as the app's layout gives it. No IO
        // event comes with it (the app sends its grid on the main actor, not through the IO's resize stream).
        let before = shown.session.frameChanges.generation
        var frame = shown.window.frame
        frame.size.width /= 2
        shown.window.setFrame(frame, display: true)
        shown.session.view.layoutSubtreeIfNeeded()
        // With `motion.frameOwner.terminals` on (FRAME OWNER S4), the surface takes its new size in the commit that
        // shows its frame drawn at that size, a refresh or two after the layout, and the change counts then; with it off
        // (the default), in the layout. The wait covers both.
        let counted = try await Self.eventually(2) { shown.session.frameChanges.generation > before }
        #expect(counted, "the surface's new size counted as no change")
        let resaved = try await Self.eventually(3) { frames.keepSaves > saves }
        #expect(resaved, "a resized terminal was not saved again within 3 s: a kill now leaves a frame the launch refuses")
    }

    /// Review of b710d40: a resized terminal that keeps changing (a spinner, a log) must still be saved at its new size
    /// (a frame of the old size is refused at launch), once the size holds, without waiting for its output to stop.
    @Test
    func aBusyResizedTerminalIsSavedAtItsNewSize() async throws {
        // Review of #35470 (T5): in both states of `motion.frameOwner.terminals` (off, the default until cmux-ad m19: the surface takes
        // its new size in the layout; on: in the commit that shows its frame, a refresh or two later).
        let shown = try await Shown()
        defer { shown.close() }
        let directory = FileManager.default.temporaryDirectory.appending(path: "keeper-busy-resize-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let frames = TerminalLaunchFrames(directory: directory)
        frames.keep("tab_busy_resized", session: shown.session, work: Self.work)
        try #require(try await Self.eventually { !Self.files("tab_busy_resized", in: directory).isEmpty }, "the first frame was never kept")
        let saves = frames.keepSaves
        var frame = shown.window.frame
        frame.size.width /= 2
        shown.window.setFrame(frame, display: true)
        shown.session.view.layoutSubtreeIfNeeded()
        // The surface shows its new size in the layout (the default), or with its frame drawn at it a refresh or two
        // later with `motion.frameOwner.terminals` on (FRAME OWNER S4). The wait covers both.
        let host = shown.session.view, target = host.surfaceSize(forHostSize: host.bounds.size)
        let showsNewSize = try await Self.eventually(2) { shown.session.surfaceView.bounds.size == target }
        try #require(showsNewSize, "the surface never showed its new size \(target)")
        let resized = shown.session.surfaceView.bounds.size
        // It never goes quiet: output every 30 ms for 4 s.
        let busyUntil = ContinuousClock.now.advanced(by: .seconds(4))
        while ContinuousClock.now < busyUntil, frames.keepSaves == saves {
            shown.io.send(.output(Data("z".utf8)))
            try await Task.sleep(for: .milliseconds(30)) // test: keystroke rate
        }
        #expect(frames.keepSaves > saves, "a busy terminal was not saved at its new size: the launch refuses its old-size frame")
        // The save's size is recorded after its GPU render ends.
        let atNewSize = try await Self.eventually(3) { frames.keepSavedSize("tab_busy_resized") == resized }
        #expect(atNewSize, "the save was not at the new size")
    }

    /// SWITCH FRAMES SF-5 (busy gate on a 2x display, 2026-11-02: 8 hidden terminals printing 20 lines/s woke
    /// `terminal.launch-frames.keep-frame` 12.6 times a second, about 2 per hidden terminal): a hidden terminal that
    /// prints costs the keeper nothing. Its first check after the hide removes its file; later output only counts
    /// (the model), with no main-actor hop and no timer, until it shows again, which saves it again.
    @Test func aHiddenBusyTerminalCostsTheKeeperNoWakes() async throws {
        let shown = try await Shown()
        defer { shown.close() }
        let directory = FileManager.default.temporaryDirectory.appending(path: "keeper-hidden-busy-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let frames = TerminalLaunchFrames(directory: directory)
        frames.keep("tab_hidden_busy", session: shown.session, work: Self.work)
        try #require(try await Self.eventually { !Self.files("tab_hidden_busy", in: directory).isEmpty }, "the shown frame was never kept")
        shown.session.isRenderingSuspended = true
        try #require(try await Self.eventually { Self.files("tab_hidden_busy", in: directory).isEmpty }, "the hidden frame was never removed")
        try await Task.sleep(for: .milliseconds(700)) // test: the hide's own check ends
        let checks = frames.keepChecks
        // 3 s of a busy program while hidden: a line every 50 ms (20 lines/s, as the busy gate).
        let end = ContinuousClock.now.advanced(by: .seconds(3))
        var lines = 0
        while ContinuousClock.now < end {
            shown.io.send(.output(Data("busy line \(lines)\r\n".utf8)))
            lines += 1
            try await Task.sleep(for: .milliseconds(50)) // test: the busy program's line rate
        }
        try await Task.sleep(for: .milliseconds(700)) // test: a check the last line asked for would run by now
        #expect(lines >= 20, "only \(lines) lines in 3 s: the test did not keep the terminal busy")
        let extra = frames.keepChecks - checks
        #expect(extra == 0, "\(extra) keeper checks (main-actor timer wakes) for \(lines) lines of a hidden terminal: hidden output must update the model only")
        // Shown again: it is kept again (the show is a change that wakes the keeper).
        shown.session.isRenderingSuspended = false
        let rekept = try await Self.eventually { !Self.files("tab_hidden_busy", in: directory).isEmpty }
        #expect(rekept, "a terminal shown again after hidden output was never kept again")
    }

    /// Review of #32384: the keeper is told when its own "on screen" changes, not only when drawing changes. With a
    /// live hover mirror (forced drawing) a hide leaves drawing on, so the keeper never heard of it: the hidden
    /// terminal's frame stayed on disk, and after a hidden check nothing kept it again when it showed.
    @Test func aHideWhileMirroredStillTellsTheKeeper() async throws {
        let shown = try await Shown()
        defer { shown.close() }
        let directory = FileManager.default.temporaryDirectory.appending(path: "keeper-mirrored-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let frames = TerminalLaunchFrames(directory: directory)
        frames.keep("tab_mirrored", session: shown.session, work: Self.work)
        try #require(try await Self.eventually { !Self.files("tab_mirrored", in: directory).isEmpty }, "the shown frame was never kept")
        shown.session.mirrorDemand = 1 // a hover card mirrors it: it draws whatever else holds
        defer { shown.session.mirrorDemand = 0 }
        shown.session.view.isHidden = true
        let removed = try await Self.eventually(3) { Self.files("tab_mirrored", in: directory).isEmpty }
        #expect(removed, "a terminal hidden while mirrored kept its frame on disk: the keeper was never told")
        shown.session.view.isHidden = false
        let rekept = try await Self.eventually { !Self.files("tab_mirrored", in: directory).isEmpty }
        #expect(rekept, "a terminal shown again while mirrored was never kept again")
    }
}

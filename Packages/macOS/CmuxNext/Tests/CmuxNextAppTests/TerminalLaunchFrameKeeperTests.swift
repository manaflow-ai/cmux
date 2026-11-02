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

    /// The key's files in `directory`.
    static func files(_ key: String, in directory: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).filter { $0.hasPrefix(key + "@") }.sorted()
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
        // A pane of the terminal host's size: its surface is the host less a legacy scroller's strip, the size the
        // frame was kept at (a mini with no mouse uses legacy scrollers).
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
    @Test func aResizedTerminalIsSavedAgainWithoutWaitingForTheInterval() async throws {
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
        #expect(shown.session.frameChanges.generation > before, "the surface's new size counted as no change")
        let resaved = try await Self.eventually(3) { frames.keepSaves > saves }
        #expect(resaved, "a resized terminal was not saved again within 3 s: a kill now leaves a frame the launch refuses")
    }

    /// Review of b710d40: a resized terminal that keeps changing (a spinner, a log) must still be saved at its new size
    /// (a frame of the old size is refused at launch), once the size holds, without waiting for its output to stop.
    @Test func aBusyResizedTerminalIsSavedAtItsNewSize() async throws {
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
}

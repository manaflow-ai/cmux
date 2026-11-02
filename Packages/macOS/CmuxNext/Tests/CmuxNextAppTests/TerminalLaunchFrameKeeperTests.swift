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
        // A pane of the terminal's size (the frame was kept at that size and the window's scale).
        let content = NSView(frame: NSRect(origin: .zero, size: shown.session.surfaceView.bounds.size))
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
        // 3 s of keystroke-rate output (every 30 ms, about 100 changes).
        let end = ContinuousClock.now.advanced(by: .seconds(3))
        var keys = 0
        while ContinuousClock.now < end {
            shown.io.send(.output(Data("x".utf8)))
            keys += 1
            try await Task.sleep(for: .milliseconds(30)) // test: keystroke rate
        }
        let extra = frames.keepSaves - saves
        #expect(keys > 50)
        #expect(extra <= 1, "\(extra) saves for \(keys) changes in 3 s: the keeper saves per change, not once per 5 s")
    }
}

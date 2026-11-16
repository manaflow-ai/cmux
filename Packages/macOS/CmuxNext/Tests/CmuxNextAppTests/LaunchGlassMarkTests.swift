import AppKit
import CmuxNextDesign
import CmuxNextDesignTokens
import CmuxNextTestSupport
import CmuxNextWakeupsTestSupport
import Testing

/// Leo 2026-11-16: "do we have an initial load logo fade in glass thing like how [a chat app] has
/// theirs/[an issue tracker] has a thing", instant first: the mark adds no delay to launch-ready. A window
/// whose content shows by its first frame never makes it; content that lands later fades in in the
/// same call that starts the mark's fade-out (a crossfade), never after it (`LaunchGlassMark`).
@MainActor @Suite(.serialized, .closesItsWindows) struct LaunchGlassMarkTests {
    final class Launch {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled],
                              backing: .buffered, defer: false)
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        /// The main pane's content, held for `.pane` as a launch pane holds it.
        let pane = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        let reveal = LaunchReveal(deadline: .seconds(60))
        let clock = ManualClock()
        let style: LaunchGlassReveal
        private(set) var marks: [String] = []
        private let events = AsyncStream.makeStream(of: String.self)
        private(set) lazy var mark = LaunchGlassMark(host: host, reveal: reveal, clock: clock, style: { [style] in style }) { [weak self] name in
            self?.marks.append(name)
            self?.events.continuation.yield(name)
        }

        init(style: LaunchGlassReveal = .bloom, holdsPane: Bool = true) {
            self.style = style
            window.isReleasedWhenClosed = false
            host.wantsLayer = true
            pane.wantsLayer = true
            host.addSubview(pane)
            window.contentView = host
            if holdsPane { reveal.hold(pane, until: .pane) }
        }

        /// Starts the mark and lets its delay pass.
        func showMark() async throws {
            mark.start()
            try await clock.waitForSleeper()
            clock.advance(by: .seconds(1))
            _ = await events.stream.first { $0 == "launch_mark.shown" }
        }

        func tearDown() {
            mark.teardown()
            window.close()
        }
    }

    @Test func contentReadyByTheFirstFrameNeverMakesTheMark() {
        let launch = Launch()
        defer { launch.tearDown() }
        launch.reveal.markReady(.pane)
        launch.mark.start()
        #expect(!launch.mark.isPending, "the mark waited for its delay over content that already showed")
        #expect(launch.mark.view == nil)
        #expect(launch.host.subviews == [launch.pane], "a layer was added for a mark that never shows")
        #expect(launch.marks.isEmpty)
    }

    /// A relaunch's saved terminal frame shows ahead of its region (`LaunchReveal.release`): the
    /// window shows content, so no mark, though another pane of it is still held.
    @Test func aSavedFrameShownAheadNeverMakesTheMark() {
        let launch = Launch()
        defer { launch.tearDown() }
        let other = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        launch.host.addSubview(other)
        launch.reveal.hold(other, until: .pane)
        launch.reveal.release(launch.pane)
        launch.mark.start()
        #expect(!launch.mark.isPending, "the mark would cover a saved terminal frame")
        #expect(launch.mark.view == nil)
    }

    /// The connecting state holds no content (cx-r650e: the empty main pane, not the mark).
    @Test func aWindowWithNothingHeldNeverMakesTheMark() {
        let launch = Launch(holdsPane: false)
        defer { launch.tearDown() }
        launch.mark.start()
        #expect(!launch.mark.isPending)
        #expect(launch.mark.view == nil)
    }

    @Test func theRevealOffNeverMakesTheMark() {
        let launch = Launch(style: .off)
        defer { launch.tearDown() }
        launch.mark.start()
        #expect(!launch.mark.isPending)
        #expect(launch.mark.view == nil)
    }

    @Test func contentWithinTheDelayNeverShowsTheMark() {
        let launch = Launch()
        defer { launch.tearDown() }
        launch.mark.start()
        #expect(launch.mark.isPending)
        launch.reveal.markReady(.pane)
        #expect(!launch.mark.isPending, "the delay outlived the content it waited for")
        #expect(launch.mark.view == nil)
        #expect(launch.marks.isEmpty)
    }

    @Test(.timeLimit(.minutes(1))) func contentAfterTheDelayCrossfadesWithTheMark() async throws {
        let launch = Launch()
        defer { launch.tearDown() }
        try await launch.showMark()
        let view = try #require(launch.mark.view)
        #expect(view.superview === launch.host)
        #expect(view.isRevealed)
        #expect(view.hitTest(NSPoint(x: 450, y: 300)) == nil, "the mark takes clicks")
        #expect(launch.pane.alphaValue == 0)
        launch.reveal.markReady(.pane)
        #expect(launch.pane.alphaValue == 1, "the mark held the content back")
        #expect(!view.isRevealed, "the mark stayed over content that came in")
        #expect(launch.marks == ["launch_mark.shown", "launch_mark.concealed"])
        launch.mark.teardown()
        #expect(launch.host.subviews == [launch.pane])
    }

    /// Every loop has a stop: the sheen's sweep ends when the mark yields.
    @Test(.timeLimit(.minutes(1))) func theSheenStopsOnConceal() async throws {
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        try #require(Motion.panes.animatesLoops && Motion.panes.duration(.launch) > 0, "the test needs animation on")
        let launch = Launch(style: .sheen)
        defer { launch.tearDown() }
        try await launch.showMark()
        let view = try #require(launch.mark.view)
        #expect(view.mark.isSweeping)
        launch.reveal.markReady(.pane)
        #expect(!view.mark.isSweeping, "the sheen kept sweeping after the mark yielded")
    }
}

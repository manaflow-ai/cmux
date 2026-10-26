import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextDesignTokens
import CmuxNextWakeupsTestSupport
import Testing

/// The corner hover's band reveal lays the window root out once per change and moves the band
/// with a clip on its layer (p03-rendering-101): an open commits at once and clips in from what
/// shows, a close clips out and commits when it lands, and a change mid-flight retargets the
/// running clip instead of placing a new one, so the shown width never jumps.
@MainActor struct CollapsedBandRevealTests {
    /// Records each clip and keeps its completion, so the test decides when a spring lands.
    @MainActor final class RecordingClip: RenderClipMotion {
        struct Change: Equatable {
            let from: CGFloat?
            let to: CGFloat
            let token: MotionSpring
        }

        var animating = true
        var changes: [Change] = []
        var completions: [@MainActor @Sendable () -> Void] = []
        var unclips = 0

        func animates(in band: NSView) -> Bool { animating }

        func clip(_ band: NSView, from start: CGFloat?, to width: CGFloat, token: MotionSpring,
                  completion: @escaping @MainActor @Sendable () -> Void) {
            changes.append(Change(from: start, to: width, token: token))
            completions.append(completion)
        }

        func unclip(_ band: NSView) { unclips += 1 }
    }

    /// A root that counts its layout passes.
    final class CountingRoot: NSView {
        var layouts = 0
        override func layout() {
            layouts += 1
            super.layout()
        }
    }

    @MainActor final class Harness {
        let clock = ManualClock()
        let clip = RecordingClip()
        let root = CountingRoot(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let band = NSView(frame: CGRect(x: 80, y: 570, width: 0, height: 28))
        let reveal: CollapsedBandReveal

        init() {
            _ = NSApplication.shared
            reveal = CollapsedBandReveal(clock: clock, clip: clip)
            root.addSubview(band)
            reveal.install(in: root, band: band)
            reveal.setSidebarHidden(true)
            settle()
        }

        /// Runs any pending layout and returns how many passes it took.
        @discardableResult
        func settle() -> Int {
            let before = root.layouts
            root.layoutSubtreeIfNeeded()
            return root.layouts - before
        }

        /// Disengages and lets the close delay pass.
        func disengageAndClose() async throws {
            reveal.setEngaged(false)
            try await clock.waitForSleeper()
            clock.advance(by: CollapsedBandReveal.closeDelay)
            await waitUntil { !reveal.isOpen }
        }

        /// Yields to the main actor until `condition` holds (the timer's action hops to it).
        func waitUntil(_ condition: () -> Bool) async {
            for _ in 0..<1_000 where !condition() { await Task.yield() }
            #expect(condition())
        }
    }

    @Test func anOpenCommitsOnceAndClipsInFromWhatShows() {
        let h = Harness()
        h.reveal.shownPresence = { 0.25 }
        h.reveal.setEngaged(true)
        #expect(h.reveal.presence == 1)
        #expect(h.settle() == 1)
        #expect(h.clip.changes == [.init(from: TitlebarToolbarBand.width * 0.25, to: TitlebarToolbarBand.width, token: .appear)])
        #expect(h.reveal.lastChangeAnimated)

        // The spring lands: no layout, the clip comes off once.
        h.clip.completions[0]()
        #expect(h.settle() == 0)
        #expect(h.clip.unclips == 1)
        #expect(h.reveal.presence == 1)
    }

    @Test func aCloseClipsOutThenCommitsWhenItLands() async throws {
        let h = Harness()
        h.reveal.setEngaged(true)
        h.clip.completions[0]()
        h.settle()

        try await h.disengageAndClose()
        // The band keeps its laid-out width under the closing clip.
        #expect(h.reveal.presence == 1)
        #expect(h.settle() == 0)
        #expect(h.clip.changes.last == .init(from: TitlebarToolbarBand.width, to: 0, token: .disappear))

        h.clip.completions[1]()
        #expect(h.reveal.presence == 0)
        #expect(h.settle() == 1)
        #expect(h.clip.unclips == 2)
    }

    @Test func openCloseOpenMidFlightRetargetsAndLandsOnce() async throws {
        let h = Harness()
        h.reveal.setEngaged(true)
        #expect(h.settle() == 1)
        try await h.disengageAndClose()
        h.reveal.setEngaged(true)
        // Open, close and open again while the first clip still runs: one layout in all, and
        // each later change continues the running clip (nil start) instead of placing a new one.
        #expect(h.settle() == 0)
        #expect(h.clip.changes.map(\.from) == [0, nil, nil])
        #expect(h.clip.changes.map(\.to) == [TitlebarToolbarBand.width, 0, TitlebarToolbarBand.width])

        // The superseded springs settle first and change nothing; the last one lands once.
        h.clip.completions[0]()
        h.clip.completions[1]()
        #expect(h.clip.unclips == 0)
        h.clip.completions[2]()
        h.clip.completions[2]()
        #expect(h.clip.unclips == 1)
        #expect(h.reveal.presence == 1)
        #expect(h.settle() == 0)
    }

    @Test func withMotionOffEachChangeCommitsInOneFrameWithNoClip() async throws {
        let h = Harness()
        h.clip.animating = false
        h.reveal.setEngaged(true)
        #expect(h.reveal.presence == 1)
        #expect(!h.reveal.lastChangeAnimated)
        #expect(h.settle() == 1)
        try await h.disengageAndClose()
        #expect(h.reveal.presence == 0)
        #expect(h.settle() == 1)
        #expect(h.clip.changes.isEmpty)
    }

    @Test func showingTheSidebarMidCloseOpensTheClipBackUp() async throws {
        let h = Harness()
        h.reveal.setEngaged(true)
        h.clip.completions[0]()
        try await h.disengageAndClose()
        h.reveal.setSidebarHidden(false)
        #expect(h.clip.changes.last == .init(from: nil, to: TitlebarToolbarBand.width, token: .appear))
        h.clip.completions[1]()
        #expect(h.clip.unclips == 1)
        h.clip.completions[2]()
        #expect(h.clip.unclips == 2)
        #expect(h.reveal.presence == 0)
    }
}

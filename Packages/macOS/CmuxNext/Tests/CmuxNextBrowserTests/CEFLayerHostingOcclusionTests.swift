import AppKit
@testable import CmuxNextBrowser
import CmuxNextWakeups
import Testing

/// A hosted page whose window is occluded (its ``WindowOcclusionFamily``: AppKit's
/// state or an opaque cmux window covering it) gets the fork's embedder visibility `occluded`, after the
/// commit like a show or hide, and `visible` once the window is seen again. Without Chromium: a fake fork,
/// and the commit runs when the test says.
@MainActor
@Suite struct CEFLayerHostingOcclusionTests {
    let fake = CEFSwitchCommitTests.FakeFork()
    /// The app-wide list of kept frames (held here: a page holds it weakly). An occluded page's frame waits
    /// in it unlocked like a hidden page's, so the next show is instant.
    let frames = CEFSwitchCommitTests.FakeFrames()
    let turn = CEFLayerHostingTests.Turn()
    let commit = CEFLayerHostingTests.Turn()
    let view = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
    let window: NSWindow

    init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: .borderless,
                          backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        window.contentView?.addSubview(view)
    }

    /// A hosted page window for browser 3 using the list, made visible by its first pass, its calls and the
    /// list's log cleared.
    func makeHostedPage() -> CEFLayerHosting {
        let turn = turn, commit = commit
        let hosting = CEFLayerHosting(isEnabled: { true }, schedule: { turn.add($0) },
                                      makePage: { ChromiumHostPageView(frame: $0, inputTarget: .pageWindow, makeLayerHost: { _ in CALayer() }) },
                                      resizeDeadlineMs: { 8 }, refreshIntervals: { [] },
                                      afterCommit: { commit.add($0) })
        hosting.view = view
        hosting.switchCommit.hiddenFrames = frames
        hosting.pageWindowCreated(browser: 3, fork: fake.fork)
        turn.end()
        commit.end()
        fake.clear()
        frames.clearLog()
        return hosting
    }

    @Test func anOccludedWindowsPageIsToldOccludedAfterTheCommit() {
        let hosting = makeHostedPage()
        #expect(hosting.switchCommit.applied == .visible)
        let family = WindowOcclusionFamily.of(window)
        #expect(family.subscribers == ["CEFLayerHosting"], "the page follows its window's family")

        family.set(occluded: true)
        #expect(fake.calls.isEmpty, "no fork call in the flip's turn")
        commit.end()
        #expect(fake.calls == ["visibility 3 occluded"])
        #expect(frames.log == ["keep"], "the occluded page's frame waits in the list, unlocked")
        #expect(hosting.switchCommit.isFrameKept)
        #expect(hosting.pageVisibility == .occluded)

        fake.clear()
        family.set(occluded: false)
        commit.end()
        #expect(fake.calls == ["visibility 3 visible"], "the kept frame shows at once: no eviction")
        #expect(frames.log == ["keep", "lock"])
        #expect(!hosting.switchCommit.isFrameEvicted)
    }

    /// The list culls an occluded page's frame like a hidden one's: past its grace, the fork lets it go.
    @Test func theListEvictsAnOccludedPagesFrame() {
        let hosting = makeHostedPage()
        WindowOcclusionFamily.of(window).set(occluded: true)
        commit.end()
        frames.evictAll()
        #expect(fake.calls == ["visibility 3 occluded", "evict 3"])
        #expect(hosting.switchCommit.isPastGrace)
    }

    /// A hidden page stays hidden whatever its window does: hidden wins over occluded.
    @Test func aHiddenPageStaysHiddenInAnOccludedWindow() {
        let hosting = makeHostedPage()
        view.isHidden = true
        hosting.visibilityMayHaveChanged()
        commit.end()
        fake.clear()
        WindowOcclusionFamily.of(window).set(occluded: true)
        commit.end()
        #expect(!fake.calls.contains { $0.hasPrefix("visibility") })
        #expect(hosting.pageVisibility == .hidden)
    }
}

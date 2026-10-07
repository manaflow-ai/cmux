import AppKit
import Testing
@testable import CmuxNextDesign

/// R111: every native scroll view follows the macOS "Show scroll bars"
/// setting live (overlay: hidden until scrolling; legacy: always shown).
@MainActor @Suite(.serialized) struct SystemScrollersTests {
    @Test func aFollowedScrollViewTakesTheSystemStyleAndFollowsChanges() {
        let saved = SystemScrollers.preferredStyleOverride
        defer {
            SystemScrollers.preferredStyleOverride = saved
            SystemScrollers.systemStyleDidChange()
        }
        SystemScrollers.preferredStyleOverride = .legacy
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        scroll.hasVerticalScroller = true
        SystemScrollers.follow(scroll)
        #expect(scroll.scrollerStyle == .legacy)
        #expect(scroll.autohidesScrollers)
        SystemScrollers.preferredStyleOverride = .overlay
        SystemScrollers.systemStyleDidChange()
        #expect(scroll.scrollerStyle == .overlay)
    }

    /// Pages get the same answer as a root class name.
    @Test func pagesGetTheStyleAsAClassName() {
        let saved = SystemScrollers.preferredStyleOverride
        defer { SystemScrollers.preferredStyleOverride = saved }
        SystemScrollers.preferredStyleOverride = .overlay
        #expect(SystemScrollers.pageValue == "overlay")
        SystemScrollers.preferredStyleOverride = .legacy
        #expect(SystemScrollers.pageValue == "legacy")
    }

    final class Recorder {
        var styles: [NSScroller.Style] = []
    }

    /// Surfaces without a plain NSScrollView (pages, the terminal) hear every change, held weakly.
    @Test func anObserverHearsEveryChangeAndIsHeldWeakly() {
        let saved = SystemScrollers.preferredStyleOverride
        defer {
            SystemScrollers.preferredStyleOverride = saved
            SystemScrollers.systemStyleDidChange()
        }
        SystemScrollers.preferredStyleOverride = .overlay
        let recorder = Recorder()
        SystemScrollers.observe(recorder) { [weak recorder] in recorder?.styles.append($0) }
        SystemScrollers.preferredStyleOverride = .legacy
        SystemScrollers.systemStyleDidChange()
        SystemScrollers.preferredStyleOverride = .overlay
        SystemScrollers.systemStyleDidChange()
        #expect(recorder.styles == [.legacy, .overlay])

        // A gone owner's handler never runs again.
        var calls = 0
        do {
            let temporary = Recorder()
            SystemScrollers.observe(temporary) { _ in calls += 1 }
        }
        SystemScrollers.systemStyleDidChange()
        #expect(calls == 0)
    }
}

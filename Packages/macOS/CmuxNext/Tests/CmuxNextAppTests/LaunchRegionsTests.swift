import AppKit
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextTabs
import CmuxNextTerminal
import Testing
@testable import CmuxNextApp

/// Launch load-in in the panes: a pane's tab strip waits for the first
/// tabs and its content for the first terminal frame, each on its own,
/// and an unavailable daemon shows everything as it is.
@MainActor
@Suite(.serialized) struct LaunchRegionsTests {
    private func pane(_ reveal: LaunchReveal) -> PaneContentView {
        let model = TabStripModel(tabs: [TabItem(id: TabID("t0"), title: "Tab")], selectedID: TabID("t0"))
        return PaneContentView(stripModel: model, reveal: reveal)
    }

    @Test(arguments: [false, true])
    func stripAndContentComeInSeparately(reduceMotion: Bool) {
        defer { Motion.reduceMotionOverride = nil }
        Motion.reduceMotionOverride = reduceMotion
        let reveal = LaunchReveal()
        let view = pane(reveal)
        #expect(view.stripView.alphaValue == 0)
        #expect(view.contentHost.alphaValue == 0)
        reveal.markReady(.tabs)
        #expect(view.stripView.alphaValue == 1)
        #expect(view.contentHost.alphaValue == 0, "the terminal has not drawn yet")
        reveal.markReady(.pane)
        #expect(view.contentHost.alphaValue == 1)
    }

    @Test func panesOpenedAfterLaunchShowAtOnce() {
        let reveal = LaunchReveal()
        reveal.markAllReady()
        let view = pane(reveal)
        #expect(view.stripView.alphaValue == 1)
        #expect(view.contentHost.alphaValue == 1)
    }

    @Test func anUnavailableDaemonShowsEveryRegion() async {
        let reveal = LaunchReveal()
        let daemon = DaemonService()
        daemon.startupDeadline = .zero
        let settle = LaunchSettle(reveal: reveal)
        settle.install(daemon: daemon)
        defer { TerminalTimings.onContentApplied = nil }
        await withCheckedContinuation { continuation in
            settle.whenSettled { continuation.resume() }
            daemon.noteStartupFailure(.binaryNotFound(searched: []))
        }
        #expect(reveal.ready == Set(LaunchRegion.allCases))
    }
}

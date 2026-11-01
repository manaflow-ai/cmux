import AppKit
@testable import CmuxNextDesign
import CmuxNextTestSupport
import Testing

/// Cmd-Tab back to cmux got slower with the session's size (user 2026-10-21: "when i cmd tab to
/// it, is laggier than before", "consider if there's a ton of workspaces and browser tabs and acp
/// chat tabs"). Since #22802 every activation re-checks every status indicator the app ever made:
/// each sidebar row of every workspace and the rows of hidden groups and parked workspaces. An
/// activation must cost the indicators on screen; a hidden one catches up when it shows again.
@MainActor @Suite(.serialized, .closesItsWindows) struct StatusIndicatorActivationCostTests {
    private struct Fixture {
        let window: NSWindow
        let parked: NSView
        let shown: [StatusIndicatorView]
        let hidden: [StatusIndicatorView]
        let center = NotificationCenter()
        let appearance: StatusIndicatorAppearance

        init(shown shownCount: Int, hidden hiddenCount: Int) {
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
                              backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            let content = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
            window.contentView = content
            parked = NSView(frame: content.bounds)
            parked.isHidden = true // a parked workspace's sidebar and strips
            content.addSubview(parked)
            appearance = StatusIndicatorAppearance(appCenter: center, workspaceCenter: NotificationCenter())
            let parked = parked
            shown = (0..<shownCount).map { _ in Self.indicator(in: content) }
            hidden = (0..<hiddenCount).map { _ in Self.indicator(in: parked) }
            for view in shown + hidden { appearance.register(view) }
        }

        static func indicator(in parent: NSView) -> StatusIndicatorView {
            let view = StatusIndicatorView(frame: NSRect(x: 0, y: 0, width: 16, height: 16))
            parent.addSubview(view)
            view.configure(.working)
            return view
        }

        func activate() -> UInt64 {
            let before = StatusIndicatorAppearance.resyncs
            center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
            return StatusIndicatorAppearance.resyncs - before
        }
    }

    @Test func anActivationChecksOnlyTheIndicatorsOnScreen() {
        let fixture = Fixture(shown: 4, hidden: 300)
        defer { fixture.window.closeAfterTest() }
        #expect(fixture.activate() == 4, "an activation re-checked indicators no one can see")
        #expect(fixture.activate() == 4)
    }

    @Test func aHiddenIndicatorCatchesUpWhenItShows() {
        let fixture = Fixture(shown: 2, hidden: 50)
        defer { fixture.window.closeAfterTest() }
        _ = fixture.activate()
        _ = fixture.activate()
        let before = StatusIndicatorAppearance.resyncs
        fixture.parked.isHidden = false
        #expect(StatusIndicatorAppearance.resyncs - before == 50, "each owed resync runs once when its view shows")
        #expect(fixture.activate() == 52)
    }

    @Test func showingAViewThatOwesNothingCostsNothing() {
        let fixture = Fixture(shown: 1, hidden: 20)
        defer { fixture.window.closeAfterTest() }
        let before = StatusIndicatorAppearance.resyncs
        fixture.parked.isHidden = false
        fixture.parked.isHidden = true
        fixture.parked.isHidden = false
        #expect(StatusIndicatorAppearance.resyncs == before)
    }
}

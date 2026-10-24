import AppKit
@testable import CmuxNextDesign
import Testing

/// Cmd-Tab back to cmux got slower with the session's size (user 2026-10-21: "when i cmd tab to
/// it, is laggier than before", "consider if there's a ton of workspaces and browser tabs and acp
/// chat tabs"). Since #22802 every activation re-checks every status indicator the app ever made:
/// each sidebar row of every workspace and the rows of hidden groups and parked workspaces. An
/// activation must cost the indicators on screen; a hidden one catches up when it shows again.
@MainActor @Suite(.serialized) struct StatusIndicatorActivationCostTests {
    private struct Fixture {
        let window: NSWindow
        let content: NSView
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
            self.content = content
            parked = NSView(frame: content.bounds)
            parked.isHidden = true // a parked workspace's sidebar and strips
            content.addSubview(parked)
            let appearance = StatusIndicatorAppearance(appCenter: center, workspaceCenter: NotificationCenter())
            self.appearance = appearance
            let parked = parked
            shown = (0..<shownCount).map { _ in Self.indicator(in: content, appearance: appearance) }
            hidden = (0..<hiddenCount).map { _ in Self.indicator(in: parked, appearance: appearance) }
        }

        static func indicator(in parent: NSView, appearance: StatusIndicatorAppearance,
                              state: StatusIndicatorState = .working) -> StatusIndicatorView {
            let view = StatusIndicatorView(frame: NSRect(x: 0, y: 0, width: 16, height: 16), appearance: appearance)
            parent.addSubview(view)
            view.configure(state)
            return view
        }

        /// Posts an activation; returns how many indicators it checked again.
        func activate() -> UInt64 {
            let before = appearance.resyncs
            center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
            return appearance.resyncs - before
        }

        /// The indicator checks `body` caused (catch-ups included).
        func checks(_ body: () -> Void) -> UInt64 {
            let before = appearance.resyncs
            body()
            return appearance.resyncs - before
        }
    }

    @Test func anActivationChecksOnlyTheIndicatorsOnScreen() {
        let fixture = Fixture(shown: 4, hidden: 300)
        #expect(fixture.activate() == 4, "an activation re-checked indicators no one can see")
        #expect(fixture.activate() == 4)
    }

    /// The moment itself must not walk every indicator the app made: a parked workspace's rows
    /// (most of a large session) are not reached at all, and still catch up when they show
    /// (perf-lead.md cause 6, Cmd-Tab become notices).
    @Test func anActivationReachesOnlyTheIndicatorsOnScreen() {
        let fixture = Fixture(shown: 4, hidden: 300)
        let before = fixture.appearance.resyncVisits
        _ = fixture.activate()
        #expect(fixture.appearance.resyncVisits - before == 4, "an activation walked indicators no one can see")
    }

    @Test func aHiddenIndicatorCatchesUpWhenItShows() {
        let fixture = Fixture(shown: 2, hidden: 50)
        _ = fixture.activate()
        _ = fixture.activate()
        #expect(fixture.checks { fixture.parked.isHidden = false } == 50, "each owed resync runs once when its view shows")
        #expect(fixture.activate() == 52)
    }

    /// A row moved (not the indicator itself) between a parked container and a shown one in the
    /// same window: AppKit tells the indicator its hidden-ancestor state flipped (`viewDidUnhide` /
    /// `viewDidHide`, NSView docs), so the resync set follows the row both ways.
    @Test func aRowMovedBetweenParkedAndShownContainersFollowsTheResyncSet() {
        let fixture = Fixture(shown: 1, hidden: 0)
        let row = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        fixture.parked.addSubview(row)
        _ = Fixture.indicator(in: row, appearance: fixture.appearance)
        #expect(fixture.activate() == 1)
        fixture.content.addSubview(row)
        #expect(fixture.activate() == 2, "the moved row's indicator is not reached by activations")
        #expect(fixture.checks { fixture.parked.addSubview(row) } == 0)
        #expect(fixture.activate() == 1, "a row moved under a parked container is still reached")
    }

    /// A member of the resync set that is off screen when a moment reaches it does not mark the
    /// moment done: it leaves the set and catches up when it shows (Leo 2026-10-20 still spinner).
    @Test func aStaleMemberOffScreenCatchesUpWhenItShows() {
        let fixture = Fixture(shown: 1, hidden: 1)
        let parkedView = fixture.hidden[0]
        fixture.appearance.setFollowsResyncs(parkedView, follows: true)
        #expect(fixture.activate() == 1, "an off-screen member did the check")
        let visits = fixture.appearance.resyncVisits
        _ = fixture.activate()
        #expect(fixture.appearance.resyncVisits - visits == 1, "the off-screen member stayed in the resync set")
        #expect(fixture.checks { fixture.parked.isHidden = false } == 1, "the moment the off-screen member missed never ran")
    }

    /// An idle indicator (hidden by its own state) that turns busy after an activation draws a
    /// fresh plan; it owes no catch-up, so the state change runs one refresh, not a second one
    /// nested inside it.
    @Test func anIdleIndicatorTurningBusyOwesNoCatchUp() {
        let fixture = Fixture(shown: 1, hidden: 0)
        let idle = Fixture.indicator(in: fixture.content, appearance: fixture.appearance, state: .idle)
        #expect(fixture.activate() == 1)
        #expect(fixture.checks { idle.configure(.working) } == 0, "turning busy ran a catch-up resync")
        #expect(fixture.activate() == 2)
    }

    @Test func showingAViewThatOwesNothingCostsNothing() {
        let fixture = Fixture(shown: 1, hidden: 20)
        #expect(fixture.checks {
            fixture.parked.isHidden = false
            fixture.parked.isHidden = true
            fixture.parked.isHidden = false
        } == 0)
    }
}

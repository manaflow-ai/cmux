import AppKit
@testable import CmuxNextDesign
import Testing

/// No O(all) work per event (perf-lead.md cause 6, row 8): a window's occlusion change (Cmd-Tab back
/// over a covering app, a minimize, a Spaces swipe) must cost the status indicators that show, not
/// every indicator the window holds. Every sidebar row and chrome spinner follows its own window's
/// occlusion (`tracksWindowOcclusion`); a row of a parked workspace, a collapsed group, or an idle row
/// (its indicator hides itself) is under a hidden view, and each one re-planned and re-labelled itself
/// on every occlusion notice. A hidden indicator listens to nothing and reads its window's state
/// when it shows.
@MainActor @Suite(.serialized) struct StatusIndicatorOcclusionCostTests {
    private struct Fixture {
        let window: NSWindow
        let parked: NSView
        let shown: [StatusIndicatorView]
        let hidden: [StatusIndicatorView]
        let idle: [StatusIndicatorView]
        let center = NotificationCenter()

        init(shown shownCount: Int, hidden hiddenCount: Int, idle idleCount: Int = 0) {
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
                              backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            let content = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
            window.contentView = content
            parked = NSView(frame: content.bounds)
            parked.isHidden = true // a parked workspace's sidebar rows and strips
            content.addSubview(parked)
            let parked = parked, center = center
            shown = (0..<shownCount).map { _ in Self.indicator(in: content, center: center, state: .working) }
            hidden = (0..<hiddenCount).map { _ in Self.indicator(in: parked, center: center, state: .working) }
            idle = (0..<idleCount).map { _ in Self.indicator(in: content, center: center, state: .idle) }
        }

        static func indicator(in parent: NSView, center: NotificationCenter, state: StatusIndicatorState) -> StatusIndicatorView {
            let view = StatusIndicatorView(frame: NSRect(x: 0, y: 0, width: 16, height: 16))
            view.notificationCenter = center
            view.tracksWindowOcclusion = true // a sidebar row's or a chrome spinner's indicator
            parent.addSubview(view)
            view.configure(state)
            return view
        }

        /// What the window says now (false on a host whose windows never report visible).
        var visible: Bool { window.occlusionState.contains(.visible) }

        /// Every indicator starts from the opposite of what the window says, so a notice that
        /// reaches one is seen on any host.
        func makeStale() {
            for view in shown + hidden + idle { view.isWindowVisible = !visible }
        }

        func postOcclusion() {
            center.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
        }
    }

    @Test func anOcclusionChangeReachesOnlyTheIndicatorsOnScreen() {
        let fixture = Fixture(shown: 3, hidden: 300, idle: 100)
        fixture.makeStale()
        fixture.postOcclusion()
        let visible = fixture.visible
        #expect(fixture.shown.allSatisfy { $0.isWindowVisible == visible }, "a shown indicator follows its window")
        let reached = (fixture.hidden + fixture.idle).filter { $0.isWindowVisible == visible }.count
        #expect(reached == 0, "an occlusion change re-planned \(reached) indicators no one can see")
    }

    @Test func aHiddenIndicatorReadsItsWindowWhenItShows() {
        let fixture = Fixture(shown: 0, hidden: 20)
        fixture.makeStale()
        fixture.postOcclusion()
        fixture.parked.isHidden = false
        let visible = fixture.visible
        #expect(fixture.hidden.allSatisfy { $0.isWindowVisible == visible }, "a shown indicator reads its window's occlusion")
        // Shown now: it follows the window again.
        fixture.makeStale()
        fixture.postOcclusion()
        #expect(fixture.hidden.allSatisfy { $0.isWindowVisible == visible })
        // Hidden again: it stops listening.
        fixture.parked.isHidden = true
        fixture.makeStale()
        fixture.postOcclusion()
        #expect(fixture.hidden.allSatisfy { $0.isWindowVisible != visible })
    }

    @Test func anIdleIndicatorThatStartsSpinningReadsItsWindow() {
        let fixture = Fixture(shown: 0, hidden: 0, idle: 5)
        fixture.makeStale()
        fixture.postOcclusion()
        for view in fixture.idle { view.configure(.working) }
        let visible = fixture.visible
        #expect(fixture.idle.allSatisfy { $0.isWindowVisible == visible }, "a spinner that shows reads its window's occlusion")
        fixture.makeStale()
        fixture.postOcclusion()
        #expect(fixture.idle.allSatisfy { $0.isWindowVisible == visible }, "and follows it from then on")
    }
}

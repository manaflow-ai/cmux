import AppKit
@testable import CmuxNextDesign
import CmuxNextWakeups
import Testing

/// A status indicator runs its loop only while its visibility node is visible.
/// The node sits under its window's node and follows AppKit's hidden state for the view; the
/// indicator observes no window notices and walks no ancestors.
@MainActor @Suite(.serialized) struct StatusIndicatorVisibilityTests {
    private struct Fixture {
        let window: NSWindow
        let content: NSView
        let source: WindowVisibilitySource
        let center = NotificationCenter()
        let screen: Screen
        /// The appearance's follows; its app notices arrive on ``center``.
        let follows: StatusIndicatorTestFollows
        /// The indicators' appearance.
        let appearance: StatusIndicatorAppearance

        /// What the test window's own state reads as.
        @MainActor final class Screen {
            var state: Visibility = .visible
        }

        init() {
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
                              backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            let screen = Screen()
            self.screen = screen
            source = WindowVisibilitySource.of(window, events: WindowEvents(window: window, center: center),
                                               read: { _ in screen.state })
            content = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
            window.contentView = content
            let windows = [window]
            follows = StatusIndicatorTestFollows(app: center)
            appearance = StatusIndicatorAppearance(windows: { windows })
            follows.start(appearance)
        }

        func indicator(in parent: NSView? = nil) -> StatusIndicatorView {
            let view = StatusIndicatorView(frame: NSRect(x: 0, y: 0, width: 16, height: 16))
            (parent ?? content).addSubview(view)
            view.configure(.busy)
            appearance.register(view)
            return view
        }

        /// The app comes to the front: the appearance resyncs its indicators.
        func activate() {
            center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        }

        func set(_ state: Visibility) {
            screen.state = state
            center.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
        }
    }

    /// The loop the configured busy look runs, or nil when the config runs none (Static look).
    private static var busyLoop: StatusIndicatorPlan.Animation? {
        let config = StatusIndicatorAppearance.shared.config
        guard config.animatesLoops else { return nil }
        return StatusIndicatorPlan.make(.busy, style: config.style(hint: nil), animates: true, set: config.iconSet,
                                        isStatic: config.isStatic, staticShapes: config.staticShapes,
                                        working: config.workingLook).animation
    }

    private static func withLoops(_ body: () throws -> Void) rethrows {
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        try body()
    }

    @Test func anOccludedOrMiniaturizedWindowStopsTheLoopAndShowingStartsIt() throws {
        try Self.withLoops {
            let fixture = Fixture()
            let view = fixture.indicator()
            let loop = try #require(Self.busyLoop)
            #expect(view.visibilityNode.parent === fixture.source.node)
            #expect(view.indicator.runningAnimation == loop)
            for hidden in [Visibility.occluded, .hidden] {
                fixture.set(hidden)
                #expect(!view.visibilityNode.isVisible)
                #expect(view.indicator.runningAnimation == nil, "a \(hidden) window keeps no loop")
                fixture.set(.visible)
                #expect(view.indicator.runningAnimation == loop, "the loop is back when the window shows")
            }
        }
    }

    @Test func aHiddenAncestorStopsTheLoop() throws {
        try Self.withLoops {
            let fixture = Fixture()
            let parked = NSView(frame: fixture.content.bounds)
            fixture.content.addSubview(parked)
            let view = fixture.indicator(in: parked)
            let loop = try #require(Self.busyLoop)
            #expect(view.indicator.runningAnimation == loop)
            parked.isHidden = true
            #expect(!view.visibilityNode.isVisible)
            #expect(view.indicator.runningAnimation == nil, "an indicator in a parked view keeps no loop")
            parked.isHidden = false
            #expect(view.indicator.runningAnimation == loop)
        }
    }

    @Test func movingIntoAHiddenViewOrOutOfTheWindowStopsTheLoop() throws {
        try Self.withLoops {
            let fixture = Fixture()
            let view = fixture.indicator()
            let loop = try #require(Self.busyLoop)
            #expect(view.indicator.runningAnimation == loop)
            let collapsed = NSView(frame: fixture.content.bounds)
            collapsed.isHidden = true
            fixture.content.addSubview(collapsed)
            collapsed.addSubview(view)
            #expect(view.indicator.runningAnimation == nil, "AppKit tells a view moved under a hidden ancestor")
            view.removeFromSuperview()
            #expect(!view.visibilityNode.isVisible)
            #expect(view.indicator.runningAnimation == nil, "an indicator in no window keeps no loop")
            fixture.content.addSubview(view)
            #expect(view.indicator.runningAnimation == loop)
        }
    }

    @Test func anIndicatorHiddenByAppKitStaysStillThroughWindowFlipsAndResyncs() throws {
        try Self.withLoops {
            let fixture = Fixture()
            let parked = NSView(frame: fixture.content.bounds)
            fixture.content.addSubview(parked)
            let views = (0..<20).map { _ in fixture.indicator(in: parked) }
            let loop = try #require(Self.busyLoop)
            #expect(views.allSatisfy { $0.indicator.runningAnimation == loop })
            parked.isHidden = true
            let before = StatusIndicatorAppearance.resyncs
            fixture.set(.occluded)
            fixture.activate()
            fixture.set(.visible)
            fixture.activate()
            #expect(StatusIndicatorAppearance.resyncs == before, "a view AppKit hides does no resync work")
            #expect(views.allSatisfy { $0.indicator.runningAnimation == nil }, "a view AppKit hides keeps no loop when its window shows")
            parked.isHidden = false
            #expect(StatusIndicatorAppearance.resyncs - before == 20, "each owed resync runs once when its view shows")
            #expect(views.allSatisfy { $0.indicator.runningAnimation == loop })
        }
    }

    /// Leo 2026-10-20: a wake that posts no occlusion notice left every spinner still. The window's
    /// node is stale until something reads the window again; the app coming back does.
    @Test func aResyncReadsTheWindowAgainWhenItsNoticeNeverCame() throws {
        try Self.withLoops {
            let fixture = Fixture()
            let view = fixture.indicator()
            let loop = try #require(Self.busyLoop)
            fixture.set(.occluded)
            #expect(view.indicator.runningAnimation == nil)
            fixture.screen.state = .visible // no occlusion notice
            #expect(view.indicator.runningAnimation == nil)
            fixture.activate()
            #expect(fixture.source.node.isVisible)
            #expect(view.indicator.runningAnimation == loop, "the resync read the window again and the loop runs")
        }
    }
}

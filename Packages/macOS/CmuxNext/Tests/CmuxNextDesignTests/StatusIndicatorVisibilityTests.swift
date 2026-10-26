import AppKit
@testable import CmuxNextDesign
import CmuxNextWakeups
import Testing

/// p06-scheduler-042: a status indicator runs its loop only while its visibility node is visible.
/// The node sits under the host's node (a row's, a tab's) or its window's, and follows AppKit's
/// hidden state for the view; the indicator observes no window notices and walks no ancestors.
@MainActor @Suite(.serialized) struct StatusIndicatorVisibilityTests {
    private struct Fixture {
        let window: NSWindow
        let content: NSView
        let source: WindowVisibilitySource
        let center = NotificationCenter()
        let screen: Screen

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
        }

        func indicator(in parent: NSView? = nil, host: VisibilityNode? = nil) -> StatusIndicatorView {
            let view = StatusIndicatorView(frame: NSRect(x: 0, y: 0, width: 16, height: 16))
            view.hostVisibility = host
            (parent ?? content).addSubview(view)
            view.configure(.busy)
            return view
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

    @Test func aHostNodeDecides() throws {
        try Self.withLoops {
            let fixture = Fixture()
            let tab = VisibilityNode("tab", own: .hidden, parent: fixture.source.node)
            let view = fixture.indicator(host: tab)
            let loop = try #require(Self.busyLoop)
            #expect(view.visibilityNode.parent === tab)
            #expect(view.indicator.runningAnimation == nil, "an indicator on a hidden tab keeps no loop")
            tab.set(.visible)
            #expect(view.indicator.runningAnimation == loop)
            tab.set(.hidden)
            #expect(view.indicator.runningAnimation == nil)
            view.hostVisibility = nil
            #expect(view.visibilityNode.parent === fixture.source.node, "without a host it follows its window")
            #expect(view.indicator.runningAnimation == loop)
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

    @Test func aHiddenIndicatorIgnoresItsWindowFlips() {
        Self.withLoops {
            let fixture = Fixture()
            let tab = VisibilityNode("tab", own: .hidden, parent: fixture.source.node)
            let views = (0..<100).map { _ in fixture.indicator(host: tab) }
            let visits = views.map(\.visibilityNode.visits)
            fixture.set(.occluded)
            fixture.set(.visible)
            #expect(views.map(\.visibilityNode.visits) == visits, "a flip of the window visits no indicator under a hidden tab")
            #expect(views.allSatisfy { $0.indicator.runningAnimation == nil })
        }
    }
}

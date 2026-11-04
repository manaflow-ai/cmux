import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDesign
@testable import CmuxNextLayout
import CmuxNextTestSupport
import CmuxNextWakeups
import QuartzCore
import Testing

/// FRAME OWNER REFACTOR S7 (window live resize). On macOS 26 and 27 AppKit resizes a window from each drag event the
/// window gets (`-[NSWindow sendEvent:]` -> its resize gesture -> `setFrame(_:display:)`), and each `setFrame` lays the
/// whole view tree out in that event's turn (`_layoutViewTree`; profile winresize-profile-b08cc6f, cmux22: 169 samples
/// under `ShellWindow.setFrame`). In the x1 film of px-window-resize-4 (FEAT DOGFOOD BUILD 8e149f2e) every queued drag
/// got its own window frame and layout pass, about 6 ms apart and back to back, so the window's frame ticks came
/// 44-62 ms apart and 52-67 refreshes dropped per film. A live-resize drag is input, as a divider drag is (S2): the
/// window applies at most one drag per display frame. The frame's first drag goes to AppKit in its own turn (no wait,
/// `WindowLiveResizeLeadingDragTests`); the window keeps only the newest of the drags after it, and its frame tick gives
/// that one to AppKit, so N drags in one display frame cost one window frame, one layout and one commit per frame.
///
/// The test is the clock (`FrameScheduler.frameDidFire` is one display frame) and stands in for AppKit's resize: the
/// right pane's content resizes the window from each drag it gets, as AppKit's gesture does, and
/// `Motion.liveResizeOverride` stands for the window's live resize (AppKit's tracking needs a real pointer). Every
/// test is synchronous, so the process-wide motion state cannot leak into another test.
@MainActor
@Suite(.serialized, .closesItsWindows)
struct WindowLiveResizeFrameTickTests {
    /// Resizes its window from each drag it gets, as AppKit's live-resize gesture does: the window's width follows the
    /// pointer from where the press was. Records each drag's pointer and the release, in the order they came.
    final class ResizeEdge: NSView {
        enum Event: Equatable, CustomStringConvertible {
            case drag(CGFloat), up

            var description: String {
                switch self {
                case let .drag(x): "drag(\(x))"
                case .up: "up"
                }
            }
        }

        private(set) var events: [Event] = []
        private var start: (width: CGFloat, x: CGFloat)?

        /// The test's window is never key: the press reaches this view all the same.
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            start = (window.frame.width, event.locationInWindow.x)
        }

        override func mouseDragged(with event: NSEvent) {
            guard let window, let start else { return }
            let x = event.locationInWindow.x
            events.append(.drag(x))
            var frame = window.frame
            frame.size.width = start.width + x - start.x
            window.setFrame(frame, display: true)
        }

        override func mouseUp(with event: NSEvent) {
            events.append(.up)
            start = nil
        }
    }

    /// Pane p2's content is the resize edge; the rest are plain layer-backed views.
    final class Panes: LayoutPaneContentProvider {
        let edge = ResizeEdge()

        func makeContentView(for pane: CmuxNextLayout.PaneID) -> NSView {
            if pane == "p2" { return edge }
            let view = NSView()
            view.wantsLayer = true
            return view
        }
    }

    /// The rig window's content view (the layout fills it). AppKit's live resize lays the window's view tree out inside
    /// each `setFrame` it applies (`_setFrameCommon` -> `_layoutViewTree`, not a window layout pass: `LayoutPassGuard`
    /// does not count it), so the tree has its final frames before `setFrame` returns. A test window is never in AppKit's
    /// live resize and its `setFrame` only marks the tree for layout: in a live resize this view lays its tree out when
    /// the window resizes it, inside the `setFrame`, as AppKit's live resize does.
    final class LiveResizeContent: NSView {
        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            if Motion.isLiveResizing(window) { layoutSubtreeIfNeeded() }
        }
    }

    /// A shell window (as the app makes it) whose content is a layout of two panes side by side.
    final class Rig {
        let provider = Panes()
        let model: LayoutModel
        let root: LayoutRootView
        let window: ShellWindow

        init() {
            _ = NSApplication.shared
            let layout = ScreenLayout.splits(.split("v", axis: .horizontal, ratio: 0.5, a: .leaf("p1"), b: .leaf("p2")))
            model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: layout)], activeScreenID: "s", focusedPane: "p1")
            model.followsDesignMetrics = false
            root = LayoutRootView(model: model, contentProvider: provider)
            root.context.reduceMotionOverride = false
            window = ShellWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 560), styleMask: [.titled, .resizable],
                                 backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let content = LiveResizeContent(frame: NSRect(x: 0, y: 0, width: 900, height: 560))
            root.frame = content.bounds
            root.autoresizingMask = [.width, .height]
            content.addSubview(root)
            window.contentView = content
            if let visible = NSScreen.main?.visibleFrame { window.setFrameOrigin(NSPoint(x: visible.minX + 40, y: visible.minY + 40)) }
            // Mouse events reach the views only in a window that was ordered in.
            window.orderFrontRegardless()
            root.layoutSubtreeIfNeeded()
            // The layout's springs step only when the test says (nothing springs in a live resize).
            root.driver.isManual = true
        }

        var edge: ResizeEdge { provider.edge }
        var screen: ScreenContentView { root.screenViews["s"]! }

        func close() { window.close() }

        func event(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                               pressure: type == .leftMouseUp ? 0 : 1)!
        }

        /// The middle of the resize edge in window coordinates (well inside the window: AppKit's own resize area along
        /// the window's edge never takes the press).
        func pressPoint() throws -> CGPoint {
            let point = edge.convert(CGPoint(x: edge.bounds.midX, y: edge.bounds.midY), to: nil)
            let frameView = try #require(window.contentView?.superview)
            try #require(frameView.hitTest(frameView.convert(point, from: nil)) === edge, "the press does not reach the resize edge")
            return point
        }

        /// One display frame of the window's display link.
        func frameTick() {
            FrameScheduler.forWindow(window).frameDidFire(timestamp: CACurrentMediaTime(), refreshInterval: 1.0 / 120)
        }

        /// Whether `pane` shows where the screen's geometry puts it (nothing springs toward another size).
        func settled(_ pane: CmuxNextLayout.PaneID) -> Bool {
            guard let shown = screen.displayedFrame(of: pane), let target = screen.geometry.panes[pane] else { return false }
            return abs(shown.minX - target.minX) < 0.5 && abs(shown.width - target.width) < 0.5
        }
    }

    @Test func liveResizeDragsInOneFrameResizeTheWindowAndLayItOutOnceAtTheFrameTick() throws {
        let rig = Rig()
        defer { rig.close() }
        let window = rig.window, screen = rig.screen
        let startWidth = window.frame.width
        let press = try rig.pressPoint()
        window.sendEvent(rig.event(.leftMouseDown, press))
        // AppKit's live resize of the window runs from its first drag to the release.
        Motion.liveResizeOverride = true
        defer { Motion.liveResizeOverride = nil }
        let reconciles = screen.reconcilePasses

        // Five drags in one display frame, back to back, as AppKit delivers the drags that queued during a long turn: the
        // frame's first reaches the resize in its own turn, the four after it wait for the frame tick.
        for step in 1...5 {
            window.sendEvent(rig.event(.leftMouseDragged, CGPoint(x: press.x + 12 * CGFloat(step), y: press.y)))
        }
        rig.root.layoutSubtreeIfNeeded()
        #expect(rig.edge.events == [.drag(press.x + 12)], "each drag reached the window's resize in its own turn: \(rig.edge.events)")
        #expect(window.frame.width == startWidth + 12, "the window took \(window.frame.width - startWidth) pt before its frame tick")
        #expect(screen.reconcilePasses - reconciles == 1, "\(screen.reconcilePasses - reconciles) screen reconciles in one display frame")

        // The window's frame tick: the newest drag resizes the window, and the layout follows it in the same turn.
        let ticked = screen.reconcilePasses, presentations = screen.presentationPasses
        rig.frameTick()
        rig.root.layoutSubtreeIfNeeded()
        #expect(rig.edge.events == [.drag(press.x + 12), .drag(press.x + 60)], "the frame tick gave the resize \(rig.edge.events)")
        #expect(window.frame.width == startWidth + 60, "the window is \(window.frame.width - startWidth) pt wider after its frame tick")
        #expect(screen.reconcilePasses - ticked == 1, "\(screen.reconcilePasses - ticked) screen reconciles for one display frame")
        #expect(screen.presentationPasses - presentations == 1,
                "\(screen.presentationPasses - presentations) presentation passes for one display frame")
        // That frame's pane rects are at the window's new size.
        #expect(screen.frame.size == rig.root.bounds.size, "screen \(screen.frame.size), root \(rig.root.bounds.size)")
        #expect(rig.settled("p1") && rig.settled("p2"), "a pane is not where the frame's layout puts it")

        // A release while a drag waits (the tick applied this display frame's drag): that drag reaches the resize first,
        // then the release, in the release's turn.
        window.sendEvent(rig.event(.leftMouseDragged, CGPoint(x: press.x + 72, y: press.y)))
        window.sendEvent(rig.event(.leftMouseUp, CGPoint(x: press.x + 72, y: press.y)))
        #expect(rig.edge.events == [.drag(press.x + 12), .drag(press.x + 60), .drag(press.x + 72), .up], "the resize got \(rig.edge.events)")
        #expect(window.frame.width == startWidth + 72, "the window ended \(window.frame.width - startWidth) pt wider")
    }

    /// `motion.frameOwner.liveResize` (Debug Settings): the switch the films compare. `body` runs with it set to `on`,
    /// in the shared tunable store (no file), and the override goes after it.
    static func withSwitch(_ on: Bool, _ body: () throws -> Void) throws {
        let key = "motion.frameOwner.liveResize"
        TunableStore.shared.activate(file: nil)
        TunableStore.shared.register(DesignTunables.all)
        try #require(TunableStore.shared.set(key, .bool(on)) == .bool(on), "Debug Settings has no \(key)")
        defer { TunableStore.shared.set(key, nil) }
        try body()
    }

    /// The switch off is today's path: each live-resize drag reaches the window's resize in its own turn.
    @Test func theSwitchOffDeliversEachLiveResizeDragInItsOwnTurn() throws {
        try Self.withSwitch(false) {
            let rig = Rig()
            defer { rig.close() }
            let window = rig.window
            let startWidth = window.frame.width
            let press = try rig.pressPoint()
            window.sendEvent(rig.event(.leftMouseDown, press))
            Motion.liveResizeOverride = true
            defer { Motion.liveResizeOverride = nil }
            for step in 1...3 {
                window.sendEvent(rig.event(.leftMouseDragged, CGPoint(x: press.x + 12 * CGFloat(step), y: press.y)))
            }
            #expect(rig.edge.events == [.drag(press.x + 12), .drag(press.x + 24), .drag(press.x + 36)], "\(rig.edge.events)")
            #expect(window.frame.width == startWidth + 36)
            window.sendEvent(rig.event(.leftMouseUp, CGPoint(x: press.x + 36, y: press.y)))
        }
    }

    /// The switch is read once per resize, at its first drag: a flip mid-resize applies from the next resize, so one
    /// resize never mixes the two paths. On, a second drag in one display frame waits for the frame tick; off, it goes
    /// in its own turn.
    @Test func theSwitchIsLatchedForTheWholeResize() throws {
        try Self.withSwitch(true) {
            let rig = Rig()
            defer { rig.close() }
            let window = rig.window
            let press = try rig.pressPoint()
            window.sendEvent(rig.event(.leftMouseDown, press))
            Motion.liveResizeOverride = true
            defer { Motion.liveResizeOverride = nil }
            window.sendEvent(rig.event(.leftMouseDragged, CGPoint(x: press.x + 12, y: press.y)))
            #expect(rig.edge.events == [.drag(press.x + 12)], "the display frame's first drag waited: \(rig.edge.events)")
            // Off mid-resize: this resize keeps the frame tick, so the frame's second drag waits for it.
            TunableStore.shared.set("motion.frameOwner.liveResize", .bool(false))
            window.sendEvent(rig.event(.leftMouseDragged, CGPoint(x: press.x + 24, y: press.y)))
            #expect(rig.edge.events == [.drag(press.x + 12)], "a flip mid-resize changed the path: \(rig.edge.events)")
            rig.frameTick()
            #expect(rig.edge.events == [.drag(press.x + 12), .drag(press.x + 24)], "\(rig.edge.events)")
            window.sendEvent(rig.event(.leftMouseUp, CGPoint(x: press.x + 24, y: press.y)))
            // The next resize reads the switch again: off, each drag in its own turn, also two in one display frame.
            window.sendEvent(rig.event(.leftMouseDown, CGPoint(x: press.x + 24, y: press.y)))
            window.sendEvent(rig.event(.leftMouseDragged, CGPoint(x: press.x + 36, y: press.y)))
            window.sendEvent(rig.event(.leftMouseDragged, CGPoint(x: press.x + 48, y: press.y)))
            #expect(rig.edge.events == [.drag(press.x + 12), .drag(press.x + 24), .up, .drag(press.x + 36), .drag(press.x + 48)],
                    "\(rig.edge.events)")
            window.sendEvent(rig.event(.leftMouseUp, CGPoint(x: press.x + 48, y: press.y)))
        }
    }

    /// Scope: outside a live resize a drag reaches its view in its own turn, as before (a text selection, a tab drag).
    @Test func outsideALiveResizeEachDragReachesItsViewInItsOwnTurn() throws {
        let rig = Rig()
        defer { rig.close() }
        let window = rig.window
        let startWidth = window.frame.width
        let press = try rig.pressPoint()
        Motion.liveResizeOverride = false
        defer { Motion.liveResizeOverride = nil }
        window.sendEvent(rig.event(.leftMouseDown, press))
        for step in 1...3 {
            window.sendEvent(rig.event(.leftMouseDragged, CGPoint(x: press.x + 12 * CGFloat(step), y: press.y)))
        }
        #expect(rig.edge.events == [.drag(press.x + 12), .drag(press.x + 24), .drag(press.x + 36)], "\(rig.edge.events)")
        #expect(window.frame.width == startWidth + 36)
        window.sendEvent(rig.event(.leftMouseUp, CGPoint(x: press.x + 36, y: press.y)))
        #expect(rig.edge.events.last == .up)
    }
}

import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDesign
@testable import CmuxNextLayout
import CmuxNextTestSupport
import CmuxNextWakeups
import QuartzCore
import Testing

/// FRAME OWNER REFACTOR S7, on a screen (display workers, gui-session-v1): AppKit's own live resize of a shell window,
/// driven from its edge with mouse events in the application's event queue (the path `debug.mouse` and the films
/// take), with `motion.frameOwner.liveResize` off and on. A burst of drags queued in one turn, as they queue behind a
/// long main-thread turn: off, AppKit resizes the window and lays it out once per drag; on, the window resizes once,
/// at its frame tick, to the newest pointer. Both end where the pointer let go.
@MainActor
@Suite(.serialized, .closesItsWindows, .timeLimit(.minutes(2)))
struct WindowLiveResizeGUITests {
    final class Panes: LayoutPaneContentProvider {
        func makeContentView(for pane: CmuxNextLayout.PaneID) -> NSView {
            let view = NSView()
            view.wantsLayer = true
            return view
        }
    }

    enum Edge: String, CaseIterable, Sendable {
        case left, top, bottomRight

        /// The press, in screen points (Cocoa, bottom-left origin), just inside the window's frame on this edge.
        func press(in frame: CGRect) -> CGPoint {
            switch self {
            case .left: CGPoint(x: frame.minX + 1, y: frame.midY)
            case .top: CGPoint(x: frame.midX, y: frame.maxY - 1)
            case .bottomRight: CGPoint(x: frame.maxX - 1, y: frame.minY + 1)
            }
        }

        /// The pointer's travel (screen points): the window grows on every edge.
        var travel: CGVector {
            switch self {
            case .left: CGVector(dx: -48, dy: 0)
            case .top: CGVector(dx: 0, dy: 36)
            case .bottomRight: CGVector(dx: 48, dy: -36)
            }
        }

        /// The frame the window rests at when the pointer moved by `travel`.
        func resized(_ frame: CGRect) -> CGRect {
            let t = travel
            switch self {
            case .left: return CGRect(x: frame.minX + t.dx, y: frame.minY, width: frame.width - t.dx, height: frame.height)
            case .top: return CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height + t.dy)
            case .bottomRight: return CGRect(x: frame.minX, y: frame.minY + t.dy, width: frame.width + t.dx, height: frame.height - t.dy)
            }
        }
    }

    static func hasDisplay() -> Bool { !NSScreen.screens.isEmpty }

    /// A mouse event at `point` (screen points) for `window`, built as `debug.mouse` builds the films' events (an
    /// NSEvent addressed to the window, its point in the window's coordinates as the window is now) and then given
    /// the global location, so AppKit reads it right while the window's origin moves under the drag.
    static func mouse(_ type: NSEvent.EventType, at point: CGPoint, window: NSWindow) throws -> NSEvent {
        let local = window.convertPoint(fromScreen: point)
        let event = try #require(NSEvent.mouseEvent(with: type, location: local, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                                    pressure: type == .leftMouseUp ? 0 : 1))
        let primary = try #require(NSScreen.screens.first).frame.maxY
        guard let cg = event.cgEvent?.copy() else { return event }
        cg.location = CGPoint(x: point.x, y: primary - point.y)
        return NSEvent(cgEvent: cg) ?? event
    }

    /// Dispatches what waits in the application's event queue, as its run loop does, in this one turn.
    static func dispatchQueued() {
        while let event = NSApp.nextEvent(matching: .any, until: .distantPast, inMode: .default, dequeue: true) {
            NSApp.sendEvent(event)
        }
    }

    @Test(.enabled("AppKit's live resize needs a window on a screen") { await Self.hasDisplay() }, arguments: Edge.allCases, [false, true])
    func aBurstOfLiveResizeDragsLaysTheWindowOutOncePerFrameAndEndsAtThePointer(_ edge: Edge, _ on: Bool) throws {
        try WindowLiveResizeFrameTickTests.withSwitch(on) {
            // AppKit's window resize gesture runs in a launched application (the films' app is one).
            if !NSApp.isRunning { NSApp.finishLaunching() }
            NSApp.activate()
            let layout = ScreenLayout.splits(.split("v", axis: .horizontal, ratio: 0.5, a: .leaf("p1"), b: .leaf("p2")))
            let model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: layout)], activeScreenID: "s", focusedPane: "p1")
            model.followsDesignMetrics = false
            let provider = Panes()
            let root = LayoutRootView(model: model, contentProvider: provider)
            let window = ShellWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500), styleMask: [.titled, .resizable],
                                     backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = root
            defer { window.close() }
            let visible = try #require(NSScreen.main?.visibleFrame)
            window.setFrame(NSRect(x: visible.midX - 400, y: visible.midY - 250, width: 800, height: 500), display: true)
            window.orderFrontRegardless()
            root.layoutSubtreeIfNeeded()
            root.driver.isManual = true
            let screen = try #require(root.screenViews["s"])
            let start = window.frame, press = edge.press(in: start), travel = edge.travel
            let steps = 8

            NSApp.postEvent(try Self.mouse(.leftMouseDown, at: press, window: window), atStart: false)
            for step in 1...steps {
                let t = CGFloat(step) / CGFloat(steps)
                NSApp.postEvent(try Self.mouse(.leftMouseDragged, at: CGPoint(x: press.x + travel.dx * t, y: press.y + travel.dy * t), window: window),
                                atStart: false)
            }
            let reconciles = screen.reconcilePasses
            Self.dispatchQueued()
            try #require(window.inLiveResize, "\(edge): AppKit did not start a live resize from the press at \(press) in \(start)")
            let inTurn = screen.reconcilePasses - reconciles
            // The window's frame tick (its display link, here the test).
            FrameScheduler.forWindow(window).frameDidFire(timestamp: CACurrentMediaTime(), refreshInterval: 1.0 / 120)
            let atTick = screen.reconcilePasses - reconciles - inTurn
            if on {
                // The first drag starts the live resize in its own turn; the 7 after it wait, and the tick resizes once.
                #expect(inTurn <= 1, "\(edge) on: \(inTurn) layouts in the drags' turn")
                #expect(atTick == 1, "\(edge) on: \(atTick) layouts at the frame tick")
            } else {
                #expect(inTurn == steps, "\(edge) off: \(inTurn) layouts for \(steps) drags")
                #expect(atTick == 0, "\(edge) off: \(atTick) layouts at the frame tick")
            }
            let end = CGPoint(x: press.x + travel.dx, y: press.y + travel.dy)
            NSApp.postEvent(try Self.mouse(.leftMouseUp, at: end, window: window), atStart: false)
            Self.dispatchQueued()
            let want = edge.resized(start)
            #expect(abs(window.frame.minX - want.minX) < 0.5 && abs(window.frame.maxX - want.maxX) < 0.5
                        && abs(window.frame.minY - want.minY) < 0.5 && abs(window.frame.maxY - want.maxY) < 0.5,
                    "\(edge) \(on ? "on" : "off"): the window rests at \(window.frame), the pointer asked for \(want)")
            #expect(screen.frame.size == root.bounds.size, "the screen is \(screen.frame.size), the root \(root.bounds.size)")
        }
    }
}

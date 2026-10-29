import AppKit
import CmuxNextAgentActivity
@testable import CmuxNextAgentLanes
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// The Chief dragged in from Home (`ChiefDragIn`, Leo 2026-10-21: "DRAG IN a Chief"): a release over a window's
/// sidebar adds it once; a release elsewhere, Escape, a lost release or the app going inactive add nothing; a
/// Chief already placed is not added again; another drag in flight keeps it from starting.
@MainActor @Suite(.serialized)
struct ChiefDragInTests {
    final class Harness {
        /// What the App's side saw: drops, and whether another drag runs.
        final class Probe {
            var drops = 0
            var busy = false
        }

        let sidebar: SidebarView
        let window: NSWindow
        let chief: ChiefSidebar
        let probe: Probe
        let drag: ChiefDragIn
        var drops: Int { probe.drops }

        init() {
            _ = NSApplication.shared
            let sidebar = SidebarView(model: SidebarModel(sections: []), design: DesignSettings.shared)
            sidebar.frame = NSRect(x: 0, y: 0, width: 240, height: 360)
            let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 600, height: 360), styleMask: [.titled],
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView?.addSubview(sidebar)
            window.orderFrontRegardless()
            sidebar.renderNow()
            sidebar.layoutSubtreeIfNeeded()
            let probe = Probe(), chief = ChiefSidebar(lanes: AgentLaneStore())
            // The App answers with the sidebar of its window under the point; here this one window.
            drag = ChiefDragIn(host: .init(sidebar: { [weak window, weak sidebar] point, _ in window?.frame.contains(point) == true ? sidebar : nil },
                                           isBusy: { probe.busy }, drop: { probe.drops += 1 }), chief: chief)
            self.sidebar = sidebar
            self.window = window
            self.probe = probe
            self.chief = chief
        }

        /// A screen point over the sidebar, or `dx` past the window's right edge.
        func over() -> CGPoint { window.convertPoint(toScreen: sidebar.convert(NSPoint(x: 100, y: 100), to: nil)) }
        func outside(dx: CGFloat = 80) -> CGPoint { CGPoint(x: window.frame.maxX + dx, y: window.frame.midY) }

        func mouse(_ type: NSEvent.EventType, at screen: CGPoint) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type, location: screen, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1))
        }

        func key(_ code: UInt16) throws -> NSEvent {
            try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                          context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: code))
        }

        func deactivated() throws -> NSEvent {
            try #require(NSEvent.otherEvent(with: .appKitDefined, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                            context: nil, subtype: NSEvent.EventSubtype.applicationDeactivated.rawValue, data1: 0, data2: 0))
        }

        func end() {
            if drag.isDragging, let escape = try? key(53) { _ = drag.handle(escape) }
            window.orderOut(nil)
        }
    }

    /// Home's page goes mid-drag: the drag keeps its `ChiefDragIn` (its monitor and ghost) until it ends, then lets go.
    /// `release`: the drag ends at its mouse-up (which AppKit sends the app however the press began), else at Escape.
    @Test(arguments: [false, true])
    func aDragOutlivesItsOwnerUntilItEnds(release: Bool) throws {
        let h = Harness()
        defer { h.end() }
        weak var weakDrag: ChiefDragIn?
        do {
            let owned = ChiefDragIn(host: .init(sidebar: { _, _ in nil }, isBusy: { false }, drop: {}), chief: h.chief)
            #expect(owned.begin(at: h.outside()))
            weakDrag = owned
        }
        var drag = try #require(weakDrag, "the drag went with its owner: its monitor and ghost stay behind") as ChiefDragIn?
        _ = drag?.handle(release ? try h.mouse(.leftMouseUp, at: h.outside()) : try h.key(53))
        #expect(drag?.isDragging == false)
        drag = nil
        #expect(weakDrag == nil, "the ended drag kept its ChiefDragIn")
    }

    @Test func aReleaseOverTheSidebarAddsTheChiefOnce() throws {
        let h = Harness()
        defer { h.end() }
        #expect(h.drag.begin(at: h.outside()))
        #expect(h.drag.handle(try h.mouse(.leftMouseDragged, at: h.over())) == nil, "the drag let its move through")
        #expect(h.drag.handle(try h.mouse(.leftMouseUp, at: h.over())) == nil)
        #expect(h.drops == 1)
        #expect(!h.drag.isDragging)
    }

    @Test func aReleaseBesideTheSidebarAddsNothing() throws {
        let h = Harness()
        defer { h.end() }
        #expect(h.drag.begin(at: h.over()))
        _ = h.drag.handle(try h.mouse(.leftMouseDragged, at: h.over()))
        _ = h.drag.handle(try h.mouse(.leftMouseUp, at: h.outside()))
        #expect(h.drops == 0, "a release outside every sidebar added the Chief")
        #expect(!h.drag.isDragging)
    }

    /// Escape, the app going inactive (its `applicationDeactivated` event) and a press whose release never came
    /// each end the drag over the sidebar with nothing added.
    @Test(arguments: ["escape", "deactivated", "press"])
    func anEndThatIsNoReleaseAddsNothing(end: String) throws {
        let h = Harness()
        defer { h.end() }
        #expect(h.drag.begin(at: h.over()))
        let event = switch end {
        case "escape": try h.key(53)
        case "deactivated": try h.deactivated()
        default: try h.mouse(.leftMouseDown, at: h.over())
        }
        _ = h.drag.handle(event)
        #expect(!h.drag.isDragging, "\(end) left the drag running")
        _ = h.drag.handle(try h.mouse(.leftMouseUp, at: h.over()))
        #expect(h.drops == 0, "\(end) still added the Chief")
    }

    @Test func aPlacedChiefIsNotAddedAgain() throws {
        let h = Harness()
        defer { h.end() }
        h.chief.isPlaced = true
        #expect(h.drag.begin(at: h.over()))
        _ = h.drag.handle(try h.mouse(.leftMouseUp, at: h.over()))
        #expect(h.drops == 0)
    }

    @Test func anotherDragInFlightKeepsItFromStarting() throws {
        let h = Harness()
        defer { h.end() }
        h.probe.busy = true
        #expect(!h.drag.begin(at: h.over()))
        #expect(!h.drag.isDragging)
        h.probe.busy = false
        #expect(h.drag.begin(at: h.over()))
        #expect(!h.drag.begin(at: h.over()), "a second drag started while one runs")
    }
}

import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDesign
import CmuxNextInput
import Foundation
import Testing

/// A link dragged out of a chat hears its events through one input tap intercept that lives for the
/// drag only (p04-input-015): it takes the drag's moves, its release and Escape, passes other keys
/// and the press after a lost release on, and every end leaves the tap's intercepts as they were.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct LinkDragSessionTests {
    let services = AppServices(environment: AppEnvironment.current([:]))
    let url = URL(fileURLWithPath: "/tmp/cmux-link-drag-session.md")

    var session: LinkDragSession { services.linkDrags }
    var tap: InputEventTap { services.inputTap }

    @Test func theDragTakesItsMovesAndPassesOtherKeys() throws {
        #expect(session.begin(url, screenPoint: DragEvents.offScreen))
        defer { _ = try? tap.send(DragEvents.key()) }
        #expect(tap.send(try DragEvents.mouse(.leftMouseDragged)) == .consume, "a responder got the drag's move")
        #expect(tap.send(try DragEvents.key(0, "a")) == .pass, "the drag took a key that is not Escape")
        #expect(session.isDragging, "another key ended the drag")
    }

    @Test(arguments: [DragEndPath.escape, .release, .pressAfterLostRelease])
    func everyEndDropsTheIntercept(_ path: DragEndPath) throws {
        let base = tap.interceptCounts
        #expect(session.begin(url, screenPoint: DragEvents.offScreen))
        #expect(tap.interceptCounts != base, "the drag installed no intercept")
        #expect(tap.send(try path.event()) == path.result, "\(path) was not \(path.result)")
        #expect(!session.isDragging, "\(path) did not end the drag")
        #expect(tap.interceptCounts == base, "\(path) left an intercept")
    }

    // MARK: The pill's host and the drop window (p03-rendering-118)

    /// A link drag started over a layout window: the session's own source pick, hold rule and input.
    @MainActor struct WindowDrag {
        let fixture: SidebarMultiViewWindowTests.Fixture
        let session: LinkDragSession
        /// Right of the sidebar, in the window's layout.
        let start: CGPoint

        init(rendersOnServer: Bool) async throws {
            let fixture = try await SidebarMultiViewWindowTests.Fixture()
            let frame = try #require(fixture.controller.window).frame
            self.fixture = fixture
            session = LinkDragSession(services: fixture.services, rendersOnServer: { rendersOnServer })
            start = CGPoint(x: frame.minX + frame.width * 0.6, y: frame.midY)
        }

        var tap: InputEventTap { fixture.services.inputTap }

        /// One move of the drag to the screen point `point`; the drag takes it.
        func move(to point: CGPoint) throws {
            #expect(tap.send(try DragEvents.mouse(.leftMouseDragged, at: point)) == .consume, "a responder got the drag's move")
        }

        func close() {
            if session.isDragging { _ = try? tap.send(DragEvents.key()) }
            fixture.close()
        }
    }

    /// With `motion.renderServer` on, a link pressed in a layout window drags with its pill in that window's
    /// overlay: the drag's moves there move one view, with no window call, and the window takes the drop.
    /// Off every screen the pill's panel shows it and no window takes the drop; back in the window the overlay
    /// holds it again.
    @Test func overItsSourceWindowThePillIsAViewOfTheOverlayAndMovesWithNoWindowCall() async throws {
        let drag = try await WindowDrag(rendersOnServer: true)
        defer { drag.close() }
        #expect(drag.session.begin(url, screenPoint: drag.start))
        let ghost = try #require(drag.session.ghost)
        #expect(drag.session.target === drag.fixture.controller, "the pressed window takes no drop")
        #expect(ghost.hostName == "window", "the pill is not a view of the source window's overlay")
        #expect(!ghost.panel.isVisible, "the pill's panel showed over its source window")

        let stats = RenderStats()
        try #require(stats.arm(), "this build has no render counters")
        let counting = await stats.ready()
        stats.reset()
        for step in 1...20 {
            try drag.move(to: CGPoint(x: drag.start.x + CGFloat(step) * 4, y: drag.start.y - CGFloat(step) * 2))
        }
        let ghostWindows: [AnyClass] = [NSPanel.self, OverlayHostPanel.self]
        let calls = stats.owners().filter { owner in ghostWindows.contains { RenderStats.classKey($0) == owner.key } }
            .reduce(0) { $0 + $1.totals[.windowCalls] }
        // Every original IMP back before the next test arms its own counters.
        stats.disarm()
        _ = await stats.ready()
        #expect(counting, "the render counters did not install")
        #expect(calls == 0, "the drag's moves over its source window made \(calls) window calls")
        #expect(ghost.hostName == "window" && !ghost.panel.isVisible, "the pill left the overlay inside its window")
        #expect(drag.session.target === drag.fixture.controller)

        try drag.move(to: DragEvents.offScreen)
        #expect(ghost.hostName == "panel" && ghost.panel.isVisible, "outside every window the panel does not show the pill")
        #expect(drag.session.target == nil, "a window took a drop outside it")

        try drag.move(to: drag.start)
        #expect(ghost.hostName == "window" && !ghost.panel.isVisible, "back over its window the overlay does not hold the pill")
        #expect(drag.session.target === drag.fixture.controller)
    }

    /// The drop window is the screen's window under the pointer: a window of the app that is no layout window
    /// (Settings, for one) over the pointer takes the drop from the layout window it covers, so a release there
    /// opens nothing, and the pill shows in its panel, over that window.
    @Test(arguments: [true, false])
    func aWindowThatIsNoLayoutWindowTakesTheDropFromTheWindowItCovers(_ rendersOnServer: Bool) async throws {
        let drag = try await WindowDrag(rendersOnServer: rendersOnServer)
        defer { drag.close() }
        #expect(drag.session.begin(url, screenPoint: drag.start))
        let ghost = try #require(drag.session.ghost)
        #expect(ghost.hostName == (rendersOnServer ? "window" : "panel"))
        let cover = NSWindow(contentRect: NSRect(x: drag.start.x + 100, y: drag.start.y - 100, width: 300, height: 200),
                             styleMask: [.borderless], backing: .buffered, defer: false)
        cover.isReleasedWhenClosed = false
        cover.orderFrontRegardless()
        defer { cover.close() }

        try drag.move(to: CGPoint(x: cover.frame.midX, y: cover.frame.midY))
        #expect(drag.session.target == nil, "the layout window under the other window took the drop")
        #expect(ghost.hostName == "panel" && ghost.panel.isVisible, "the pill does not show over the other window")

        try drag.move(to: drag.start)
        #expect(drag.session.target === drag.fixture.controller, "the uncovered layout window takes no drop")
        #expect(ghost.hostName == (rendersOnServer ? "window" : "panel"))
    }
}

/// The ways a drag ends from its input, the event that ends it, and what the tap does with it.
nonisolated enum DragEndPath: CustomStringConvertible, Sendable {
    case escape, release, pressAfterLostRelease

    @MainActor func event() throws -> NSEvent {
        switch self {
        case .escape: try DragEvents.key()
        case .release: try DragEvents.mouse(.leftMouseUp)
        case .pressAfterLostRelease: try DragEvents.mouse(.leftMouseDown)
        }
    }

    /// Escape and the release stop at the drag; the press goes on to what it hit.
    var result: InputEventTap.InterceptResult { self == .pressAfterLostRelease ? .pass : .consume }

    var description: String {
        switch self {
        case .escape: "Escape"
        case .release: "the release"
        case .pressAfterLostRelease: "a press after a lost release"
        }
    }
}

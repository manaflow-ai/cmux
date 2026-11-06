import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDesign
@testable import CmuxNextLayout
import Testing

/// RESIZE MAIN BUDGET (cmux-ad m36). After #36485 and #36547 a STRESS drag frame still spent 0.85 ms in AppKit's
/// structural-region pass (drag margins 0.56 ms, the tracking-area update 0.28 ms; Time Profiler of job f1ade771,
/// cmux19-perf, 120 Hz), and `-[NSView setFrameSize:]` of each moved pane host walked its subtree to mark tracking areas
/// dirty (`_recursiveSetTrackingAreasDirty`). Its trigger is any view inside a moved pane that still owns an
/// NSTrackingArea. Inside a layout screen only the screen owns one (Chrome's model: one pointer area per window; pane
/// content is served by it, ``PanePointerFollowing`` / ``PanePointerRegion``). This lists every other owner by class.
@MainActor
@Suite(.serialized, .closesItsWindows)
struct PaneTrackingAreaOwnersTests {
    /// Views below `root` (not the screens) that own a tracking area now, by class.
    static func owners(in root: NSView) -> [String: Int] {
        var found: [String: Int] = [:]
        var stack = [root]
        while let view = stack.popLast() {
            if !(view is ScreenContentView), !view.trackingAreas.isEmpty {
                found[String(describing: type(of: view)), default: 0] += 1
            }
            stack.append(contentsOf: view.subviews)
        }
        return found
    }

    /// The 2x2 rig in the app's window, at rest, then through one key resize (Ctrl-Shift-L on p2) to its landing.
    static func resized(_ rig: PaneGroundCoversPaneTests.Rig, in window: NSWindow) throws {
        window.orderFrontRegardless()
        try #require(window.isVisible, "the window is not on screen: this test needs a display worker")
        window.displayIfNeeded()
        CATransaction.flush()
        try #require(PaneResize.press("p2", .right, model: rig.model, view: rig.root), "the press was refused")
        rig.root.syncWithModel()
        var frames = 0
        while frames < 240, rig.frame() { frames += 1 }
        rig.commit()
        window.displayIfNeeded()
        CATransaction.flush()
        try #require(frames > 3, "the press did not spring (\(frames) frames)")
    }

    /// During and after a key resize, no view inside the layout screen owns a tracking area.
    @Test func noViewInsideALayoutScreenOwnsATrackingArea() throws {
        let rig = PaneGroundCoversPaneTests.Rig(PaneMotionPointerAreasTests.grid, focused: "p2")
        defer { rig.close() }
        let window = PaneMotionPointerAreasTests.shellWindow(rig)
        defer { window.closeAfterTest() }
        try Self.resized(rig, in: window)
        let owners = Self.owners(in: try rig.screen)
        print("HPA-COUNT case=pane-tracking-area-owners \(owners.sorted { $0.value > $1.value }.map { "\($0.key):\($0.value)" }.joined(separator: ","))")
        #expect(owners.isEmpty, "views inside the layout screen own tracking areas: \(owners)")
    }

    /// A person's hover still works: after a key resize, the pointer moving onto a strip button in a pane that moved
    /// lights it, and moving off clears it, from the screen's one area alone (no own tracking area of the button).
    @Test func aStripButtonInAMovedPaneLightsUnderThePointerAfterTheResize() throws {
        let rig = PaneGroundCoversPaneTests.Rig(PaneMotionPointerAreasTests.grid, focused: "p2")
        defer { rig.close() }
        let window = PaneMotionPointerAreasTests.shellWindow(rig)
        defer { window.closeAfterTest() }
        defer { PointerHover.debugPointers[ObjectIdentifier(window)] = nil }
        try Self.resized(rig, in: window)
        let screen = try rig.screen
        let host = try #require(rig.root.context.hosts["p1"])
        let button = try #require(PaneMotionPointerAreasTests.first(TitlebarBandButton.self, in: host), "p1 shows no strip button")
        try #require(!button.isHiddenOrHasHiddenAncestor && button.bounds.width > 0, "the strip button does not show")
        func move(to point: NSPoint?) throws {
            // The pointer, with no refresh of its own: only the screen's area hears the move.
            PointerHover.debugPointers[ObjectIdentifier(window)] = .init(point: point, mouse: NSEvent.mouseLocation)
            let at = point ?? NSPoint(x: -10, y: -10)
            let event = try #require(NSEvent.mouseEvent(with: .mouseMoved, location: at, modifierFlags: [], timestamp: 0,
                                                        windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                        clickCount: 0, pressure: 0))
            screen.dividerPointer.mouseMoved(with: event)
        }
        let over = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
        try move(to: over)
        #expect(button.hover.state.hovering, "the strip button did not light under the pointer after the resize")
        try move(to: host.convert(NSPoint(x: host.bounds.midX, y: host.bounds.midY), to: nil))
        #expect(!button.hover.state.hovering, "the strip button stayed lit after the pointer left it")
    }
}

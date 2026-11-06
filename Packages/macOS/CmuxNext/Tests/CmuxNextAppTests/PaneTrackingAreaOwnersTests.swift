import AppKit
@testable import CmuxNextApp
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

    @Test func noViewInsideALayoutScreenOwnsATrackingArea() throws {
        let rig = PaneGroundCoversPaneTests.Rig(PaneMotionPointerAreasTests.grid, focused: "p2")
        defer { rig.close() }
        let window = PaneMotionPointerAreasTests.shellWindow(rig)
        defer { window.closeAfterTest() }
        window.orderFrontRegardless()
        try #require(window.isVisible, "the window is not on screen: this test needs a display worker")
        window.displayIfNeeded()
        CATransaction.flush()
        let screen = try rig.screen
        let owners = Self.owners(in: screen)
        print("HPA-COUNT case=pane-tracking-area-owners \(owners.sorted { $0.value > $1.value }.map { "\($0.key):\($0.value)" }.joined(separator: ","))")
        #expect(owners.isEmpty, "views inside the layout screen own tracking areas: \(owners)")
    }
}

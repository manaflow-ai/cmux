import AppKit
@testable import CmuxNextDesign
import Testing

/// GeometryReentrancyGuard (p10-stability-192): a view that re-enters its own
/// geometry callback is stopped at ``GeometryReentrancyGuard/maxDepth`` and
/// reported once, instead of overflowing the stack (Crash D, #24998).
@MainActor
@Suite(.serialized) struct GeometryReentrancyGuardTests {
    #if DEBUG
    typealias Callback = GeometryReentrancyGuard.Callback

    /// Not final, and resized through an `NSView` reference: AppKit's
    /// `setFrameSize:` calls `resizeSubviewsWithOldSize:`, which resizes the
    /// view again, so every frame change re-enters NSView's `setFrameSize:`.
    class SelfResizingView: NSView {
        var resizes = 0

        override func resizeSubviews(withOldSize oldSize: NSSize) {
            super.resizeSubviews(withOldSize: oldSize)
            resizes += 1
            // Without the guard the test fails here instead of overflowing the stack.
            guard resizes < 200 else { return }
            setFrameSize(NSSize(width: frame.width + 1, height: frame.height))
        }
    }

    @Test func depthTableOpensAtMostTheLimitPerViewAndCallback() {
        let first = NSView()
        let second = NSView()
        let a = ObjectIdentifier(first)
        let b = ObjectIdentifier(second)
        let type = ObjectIdentifier(NSView.self)
        var table = GeometryDepthTable()
        for _ in 0..<3 { #expect(table.enter(a, type: type, .layout, limit: 3) == .entered) }
        #expect(table.enter(a, type: type, .layout, limit: 3) == .refused(depth: 4, first: true))
        #expect(table.enter(a, type: type, .layout, limit: 3) == .refused(depth: 4, first: false))
        #expect(table.depth(of: a, .layout) == 3)
        // Another callback of the same view and the same callback of another view have their own depths.
        #expect(table.enter(a, type: type, .frameSize, limit: 3) == .entered)
        for _ in 0..<3 { #expect(table.enter(b, type: type, .layout, limit: 3) == .entered) }
        // One report per view class and callback.
        #expect(table.enter(b, type: type, .layout, limit: 3) == .refused(depth: 4, first: false))
        table.exit(a, .layout)
        #expect(table.depth(of: a, .layout) == 2)
        #expect(table.enter(a, type: type, .layout, limit: 3) == .entered)
        table.clearDepths()
        #expect(table.isIdle)
        table.exit(a, .layout)
        #expect(table.depth(of: a, .layout) == 0)
    }

    /// A call that re-enters itself through the gate runs ``maxDepth`` times,
    /// then the next call is refused: one report, no overflow.
    @Test func gateStopsASelfRecursiveCallAtTheLimitAndReportsOnce() {
        let guardian = GeometryReentrancyGuard()
        var delivered: [GeometryReentrancyGuard.Report] = []
        guardian.onReentry = { delivered.append($0) }
        let view = NSView()
        var runs = 0
        func recurse() {
            guardian.gate.run(view, .boundsSize) {
                runs += 1
                if runs < 1_000 { recurse() }
            }
        }
        recurse()
        #expect(runs == GeometryReentrancyGuard.maxDepth)
        #expect(guardian.refusals == 1)
        #expect(guardian.reports.map(\.callback) == [.boundsSize])
        #expect(guardian.reports.first?.viewClass == String(describing: NSView.self))
        #expect(guardian.reports.first?.depth == GeometryReentrancyGuard.maxDepth + 1)
        #expect(delivered == guardian.reports)

        // The depths closed as the calls returned: the same recursion runs as deep again, unreported.
        runs = 0
        recurse()
        #expect(runs == GeometryReentrancyGuard.maxDepth)
        #expect(guardian.refusals == 2)
        #expect(guardian.reports.count == 1)
        #expect(delivered.count == 1)
    }

    /// Nesting below the limit, and other views inside it, run untouched.
    @Test func gatePassesNestingBelowTheLimitAndOtherViews() {
        let guardian = GeometryReentrancyGuard()
        let outer = NSView()
        let inner = NSView()
        var innerRuns = 0
        func nest(_ depth: Int) {
            guardian.gate.run(outer, .layout) {
                if depth < GeometryReentrancyGuard.maxDepth {
                    nest(depth + 1)
                } else {
                    for _ in 0..<3 { guardian.gate.run(inner, .layout) { innerRuns += 1 } }
                }
            }
        }
        nest(1)
        #expect(innerRuns == 3)
        #expect(guardian.refusals == 0)
        #expect(guardian.reports.isEmpty)
    }

    /// The installed guard stops a view whose frame change resizes it again
    /// inside AppKit's `setFrameSize:`; installing twice wraps once.
    @Test func installedGuardStopsASelfResizingView() {
        LayoutPassGuard.shared.install()
        let guardian = LayoutPassGuard.shared.geometry
        guardian.install()
        #expect(guardian.isInstalled)
        let resizing = SelfResizingView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        resizing.addSubview(NSView(frame: NSRect(x: 0, y: 0, width: 5, height: 5)))
        let view: NSView = resizing
        let refusalsBefore = guardian.refusals
        view.setFrameSize(NSSize(width: 20, height: 10))
        #expect(resizing.resizes == GeometryReentrancyGuard.maxDepth)
        #expect(guardian.refusals == refusalsBefore + 1)
        let viewClass = String(describing: SelfResizingView.self)
        let matching = guardian.reports.filter { $0.viewClass == viewClass && $0.callback == .frameSize }
        #expect(matching.count == 1)

        resizing.resizes = 0
        view.setFrameSize(NSSize(width: 40, height: 10))
        #expect(resizing.resizes == GeometryReentrancyGuard.maxDepth)
        #expect(guardian.reports.filter { $0.viewClass == viewClass && $0.callback == .frameSize }.count == 1)
    }
    #endif
}

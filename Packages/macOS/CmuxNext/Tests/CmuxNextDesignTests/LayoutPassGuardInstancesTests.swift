#if DEBUG || CMUX_BENCH_HOOKS
import AppKit
@testable import CmuxNextDesign
import Testing

/// FRAME OWNER REFACTOR S7b: `debug.layers` `top_instances`. The class counts (`top_classes`) said the titlebar's
/// `_NSCoreHostingView<RootView>` laid out about 7.6 and 3.8 times per tick of a live resize, but not which two views
/// those are. The guard now counts per view, from a reset on (benches and films), with each view's superview chain.
/// The guard is one per process (it swizzles AppKit), so the test reads only what it counts after its own reset.
@MainActor
@Suite(.serialized)
struct LayoutPassGuardInstancesTests {
    final class Leaf: NSView {}
    final class Holder: NSView {}

    @Test func countsEachViewsLayoutCallsFromAResetOnWithItsSuperviewChain() {
        let guardian = LayoutPassGuard.shared
        guardian.install()
        let holder = Holder(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        let busy = Leaf(frame: NSRect(x: 0, y: 0, width: 10, height: 10)), quiet = Leaf(frame: NSRect(x: 20, y: 0, width: 10, height: 10))
        holder.addSubview(busy)
        holder.addSubview(quiet)

        // Before this test's reset: whatever an earlier test of the process counted is cleared by it.
        busy.layout()
        guardian.reset()
        for _ in 0..<3 { busy.layout() }
        quiet.layout()
        let leaves = guardian.instancesByCalls(limit: 10).filter { $0.viewClass == String(describing: Leaf.self) }
        #expect(leaves.map { $0.calls } == [3, 1], "per-view layout calls after the reset: \(leaves)")
        #expect(leaves.first?.ancestry.first == String(describing: Holder.self), "the busy view's superview chain: \(leaves)")
        #expect(guardian.instancesByCalls(limit: 1).count == 1, "the limit")
    }
}
#endif

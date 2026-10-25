import AppKit
import CmuxNextCompat
@testable import CmuxNextDesign
import ObjectiveC
import QuartzCore
import Testing

/// RenderStats (p03-rendering-001): render work counted per owner class only while armed, for the
/// counting benches (`debug.frames` with `render: true`, `debug.damage`).
@MainActor
@Suite(.serialized) struct RenderStatsTests {
    #if DEBUG || CMUX_BENCH_HOOKS
    // Not final, and called through an `NSView` reference: a call Swift could devirtualize would skip
    // the Objective-C dispatch that AppKit (and the hooks) use.
    class PlainView: NSView {}

    class SuperCallingView: NSView {
        override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize) }
    }

    class DrawingView: NSView {
        override var wantsUpdateLayer: Bool { true }
        override func updateLayer() {}
        override func draw(_ dirtyRect: NSRect) {}
    }

    final class ProbeWindow: NSWindow {}

    nonisolated final class ProbeLayer: CALayer {}

    nonisolated final class OffMainCalls: Sendable {
        let count = Atomic<Int>(0)
    }

    private func count(_ stats: RenderStats, _ counter: RenderStats.Counter, owner: AnyClass) -> Int {
        stats.owners().first { $0.id == ObjectIdentifier(owner) }?.totals[counter] ?? 0
    }

    private func rootIMPs() -> [IMP?] {
        RenderStats.hookedSelectors.flatMap { root, selectors in
            selectors.map { selector in class_getInstanceMethod(root, selector).map(method_getImplementation) }
        }
    }

    /// Disarmed, every hooked method runs its original IMP; armers nest, and the last disarm restores.
    @Test func disarmedHooksAreTheOriginalIMPs() {
        let stats = RenderStats()
        let original = rootIMPs()
        #expect(original.allSatisfy { $0 != nil })
        #expect(stats.arm())
        let armed = rootIMPs()
        for index in original.indices { #expect(armed[index] != original[index]) }
        stats.arm()
        stats.disarm()
        #expect(stats.isArmed)
        #expect(rootIMPs() == armed)
        stats.disarm()
        #expect(!stats.isArmed)
        #expect(rootIMPs() == original)
        // A second arm reuses the same hooks.
        stats.arm()
        #expect(rootIMPs() == armed)
        stats.disarm()
        #expect(rootIMPs() == original)
    }

    @Test func threeFrameSetsCountThreeAndAnEqualSetCountsZero() {
        let view: NSView = PlainView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        let stats = RenderStats()
        stats.arm()
        view.setFrameSize(NSSize(width: 20, height: 20))
        view.setFrameSize(NSSize(width: 30, height: 30))
        view.setFrameOrigin(NSPoint(x: 5, y: 5))
        #expect(count(stats, .frameSets, owner: PlainView.self) == 3)
        view.setFrameSize(NSSize(width: 30, height: 30))
        view.setFrameOrigin(NSPoint(x: 5, y: 5))
        view.frame = NSRect(x: 5, y: 5, width: 30, height: 30)
        #expect(count(stats, .frameSets, owner: PlainView.self) == 3)
        stats.disarm()
        view.setFrameSize(NSSize(width: 40, height: 40))
        #expect(count(stats, .frameSets, owner: PlainView.self) == 3)
    }

    /// An override that calls `super` is one set, counted at the override's class.
    @Test func anOverrideCallingSuperCountsOnce() {
        let view: NSView = SuperCallingView(frame: .zero)
        let stats = RenderStats()
        stats.arm()
        defer { stats.disarm() }
        for side in [10.0, 20.0, 30.0] { view.setFrameSize(NSSize(width: side, height: side)) }
        #expect(count(stats, .frameSets, owner: SuperCallingView.self) == 3)
        #expect(stats.totals[.frameSets] == 3)
    }

    @Test func updateLayerAndDrawCountDamageRectsAndArea() {
        let view: NSView = DrawingView(frame: NSRect(x: 0, y: 0, width: 10, height: 20))
        let stats = RenderStats()
        stats.arm()
        defer { stats.disarm() }
        view.updateLayer()
        view.draw(NSRect(x: 0, y: 0, width: 5, height: 4))
        #expect(count(stats, .damageRects, owner: DrawingView.self) == 2)
        #expect(count(stats, .damageArea, owner: DrawingView.self) == 200 + 20)
    }

    @Test func trackingAreaAddsCount() {
        let view: NSView = PlainView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        let stats = RenderStats()
        stats.arm()
        defer { stats.disarm() }
        view.addTrackingArea(NSTrackingArea(rect: view.bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: view))
        #expect(count(stats, .trackingAreaAdds, owner: PlainView.self) == 1)
    }

    @Test func windowCallsCountOnlyChanges() {
        let window: NSWindow = ProbeWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.borderless],
                                 backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let stats = RenderStats()
        stats.arm()
        defer { stats.disarm() }
        window.setFrame(NSRect(x: 10, y: 10, width: 300, height: 120), display: false)
        window.setFrame(window.frame, display: false)
        window.alphaValue = 0.5
        window.alphaValue = 0.5
        #expect(count(stats, .windowCalls, owner: ProbeWindow.self) == 2)
    }

    /// Renderer threads set layer contents: every change counts, a repeat of the same object does not, and the
    /// counters take it without a data race (run under TSan: `swift test --sanitize=thread`).
    @Test func contentsSetsFromBackgroundThreadsCountWithoutARace() async {
        let stats = RenderStats()
        stats.arm()
        defer { stats.disarm() }
        let (offMain, sets) = await Self.setContentsOffMain(threads: 8, setsPerThread: 50)
        #expect(offMain == 8)
        #expect(sets == 8 * 50)
        #expect(count(stats, .contentsSets, owner: ProbeLayer.self) == sets)
    }

    /// Each thread sets two images in turn on its own layer, then the last one again (no change).
    /// Returns the threads that ran off the main thread and the changing sets made.
    nonisolated static func setContentsOffMain(threads: Int, setsPerThread: Int) async -> (offMain: Int, sets: Int) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let offMain = OffMainCalls()
                let sets = OffMainCalls()
                DispatchQueue.concurrentPerform(iterations: threads) { _ in
                    if !Thread.isMainThread { offMain.count.add(1, ordering: .relaxed) }
                    let images = [image(gray: 0), image(gray: 1)].compactMap { $0 }
                    guard images.count == 2 else { return }
                    let layer = ProbeLayer()
                    for index in 0..<setsPerThread { layer.contents = images[index % 2] }
                    layer.contents = images[(setsPerThread - 1) % 2]
                    sets.count.add(setsPerThread, ordering: .relaxed)
                }
                continuation.resume(returning: (offMain.count.load(ordering: .relaxed), sets.count.load(ordering: .relaxed)))
            }
        }
    }

    nonisolated static func image(gray: CGFloat) -> CGImage? {
        guard let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(CGColor(gray: gray, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        return context.makeImage()
    }

    /// A method a class gains while disarmed (TypingFrameProbe adds `setContents:` to a layer class at runtime)
    /// is hooked by the next arm, and the call it forwards to `CALayer` counts once.
    @Test func aMethodAddedWhileDisarmedIsHookedByTheNextArm() {
        let stats = RenderStats()
        stats.arm()
        stats.disarm()
        let layerClass: AnyClass = AddedMethodLayer.self
        let selector = #selector(setter: CALayer.contents)
        typealias SetContents = @convention(c) (AnyObject, Selector, AnyObject?) -> Void
        if let inherited = class_getInstanceMethod(CALayer.self, selector) {
            let forward = unsafeBitCast(method_getImplementation(inherited), to: SetContents.self)
            let block: @convention(block) (AnyObject, AnyObject?) -> Void = { layer, contents in forward(layer, selector, contents) }
            class_addMethod(layerClass, selector, imp_implementationWithBlock(block), method_getTypeEncoding(inherited))
        }
        stats.arm()
        defer { stats.disarm() }
        let layer = AddedMethodLayer()
        layer.contents = Self.image(gray: 0)
        layer.contents = Self.image(gray: 1)
        #expect(count(stats, .contentsSets, owner: AddedMethodLayer.self) == 2)
        #expect(stats.owners().filter { $0.name.contains("AddedMethodLayer") }.count == 1)
    }

    nonisolated final class AddedMethodLayer: CALayer {}

    @Test func armingRoutesLayoutPassGuardLayoutCalls() {
        let guardian = LayoutPassGuard.shared
        let stats = RenderStats(layoutGuard: guardian)
        stats.arm()
        #expect(guardian.renderStats === stats)
        stats.recordLayout(of: PlainView.self)
        #expect(count(stats, .layouts, owner: PlainView.self) == 1)
        stats.disarm()
        #expect(guardian.renderStats == nil)
        stats.recordLayout(of: PlainView.self)
        #expect(count(stats, .layouts, owner: PlainView.self) == 1)
    }

    /// Owners past the table's capacity still count, in the overflow cell, and the totals stay whole.
    @Test func ownersPastCapacityGoToTheOverflowCell() {
        let stats = RenderStats(ownerCapacity: 1)
        stats.arm()
        defer { stats.disarm() }
        stats.recordLayout(of: PlainView.self)
        stats.recordLayout(of: DrawingView.self)
        stats.recordLayout(of: DrawingView.self)
        #expect(stats.totals[.layouts] == 3)
        #expect(stats.owners().map(\.totals[.layouts]).sorted() == [1, 2])
        stats.reset()
        #expect(stats.totals == RenderStats.Totals())
        #expect(stats.owners().isEmpty)
    }

    @Test func infiniteAnimationsCountOnlyWhereNobodySeesThem() {
        let root = CALayer()
        let hidden = CALayer()
        hidden.isHidden = true
        let shown = CALayer()
        root.addSublayer(hidden)
        root.addSublayer(shown)
        let loop = CABasicAnimation(keyPath: "opacity")
        loop.repeatCount = .infinity
        let once = CABasicAnimation(keyPath: "opacity")
        hidden.add(loop, forKey: "loop")
        hidden.add(once, forKey: "once")
        shown.add(loop, forKey: "loop")
        var counts: [String: Int] = [:]
        RenderStats.countHiddenLoops(in: root, hidden: false, into: &counts)
        #expect(counts == [String(describing: CALayer.self): 1])
        counts = [:]
        // A window nobody sees hides every layer in it.
        RenderStats.countHiddenLoops(in: root, hidden: true, into: &counts)
        #expect(counts == [String(describing: CALayer.self): 2])
    }
    #else
    @Test func releaseBuildsHaveNoHooks() {
        let stats = RenderStats()
        #expect(!RenderStats.isAvailable)
        #expect(!stats.arm())
        #expect(!stats.isArmed)
    }
    #endif
}

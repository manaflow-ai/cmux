import AppKit
import CmuxNextCompat
@testable import CmuxNextDesign
import ObjectiveC
import QuartzCore
import Testing

/// RenderStats: render work counted per owner class only while armed, for the
/// counting benches (`debug.frames` with `render: true`, `debug.damage`), and RenderFrameLog, its
/// per-frame view for `debug.frames`. One serialized suite: the hooks are process-wide.
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

    /// Two views that do not draw, each first displayed in one state (disarmed, armed).
    class DisarmedBackedView: NSView {}
    class ArmedBackedView: NSView {}

    final class ProbeWindow: NSWindow {}

    nonisolated final class ProbeLayer: CALayer {}
    nonisolated final class AddedWhileDisarmedLayer: CALayer {}
    nonisolated final class AddedWhileArmedLayer: CALayer {}

    nonisolated final class OffMainCalls: Sendable {
        let count = Atomic<Int>(0)
    }

    private typealias SetContents = @convention(c) (AnyObject, Selector, AnyObject?) -> Void
    private static let setContents = #selector(setter: CALayer.contents)

    private func count(_ stats: RenderStats, _ counter: RenderStats.Counter, owner: AnyClass) -> Int {
        stats.owners().first { $0.key == RenderStats.classKey(owner) }?.totals[counter] ?? 0
    }

    /// `stats` armed and counting.
    private func armed(_ stats: RenderStats = RenderStats()) async -> RenderStats {
        #expect(stats.arm())
        #expect(await stats.ready())
        return stats
    }

    /// Ends every arm of `stats` and waits until its IMPs are back, so the next test's instance never
    /// captures its hooks as originals.
    private func release(_ stats: RenderStats) async {
        while stats.isArmed { stats.disarm() }
        _ = await stats.ready()
    }

    /// The IMPs of every method hooked on its root, and of the test classes' own hooked methods.
    private func hookedIMPs() -> [IMP?] {
        let roots = RenderStats.hookedMethods().filter(\.onRoot).map { class_getInstanceMethod($0.root, $0.selector) }
        let subclasses = [
            class_getInstanceMethod(SuperCallingView.self, #selector(NSView.setFrameSize(_:))),
            class_getInstanceMethod(DrawingView.self, #selector(NSView.updateLayer)),
            class_getInstanceMethod(DrawingView.self, #selector(NSView.draw(_:))),
        ]
        return (roots + subclasses).map { $0.map(method_getImplementation) }
    }

    /// NSView's own `drawRect:` and `updateLayer`, which the hooks never replace.
    private func viewDrawingIMPs() -> [IMP?] {
        [#selector(NSView.draw(_:)), #selector(NSView.updateLayer)].map { class_getMethodImplementation(NSView.self, $0) }
    }

    /// Disarmed, every hooked method (root and subclass) runs its original IMP; armers nest, and the last
    /// disarm restores. NSView's `drawRect:` and `updateLayer` stay NSView's own while armed.
    @Test func disarmedHooksAreTheOriginalIMPs() async {
        let original = hookedIMPs()
        let drawing = viewDrawingIMPs()
        #expect(original.allSatisfy { $0 != nil })
        let stats = await armed()
        let armedIMPs = hookedIMPs()
        for index in original.indices { #expect(armedIMPs[index] != original[index]) }
        #expect(viewDrawingIMPs() == drawing)
        stats.arm()
        stats.disarm()
        #expect(stats.isCounting)
        #expect(hookedIMPs() == armedIMPs)
        stats.disarm()
        #expect(!stats.isArmed)
        #expect(!stats.isCounting)
        await release(stats)
        #expect(hookedIMPs() == original)
        // A second arm reuses the same hooks.
        _ = await armed(stats)
        #expect(hookedIMPs() == armedIMPs)
        await release(stats)
        #expect(hookedIMPs() == original)
    }

    /// Two probes (`debug.frames`, `debug.damage`) share the app's one instance: it counts until both
    /// end their arms, and in either disarm order every IMP ends as the original.
    @Test func twoArmersShareOneInstanceAndEitherDisarmOrderRestoresTheIMPs() async {
        let original = hookedIMPs()
        let stats = RenderStats()
        let frames = RenderFrameLog(stats: stats, windows: { [] })
        let damage = RenderFrameLog(stats: stats, windows: { [] })
        for order in [[frames, damage], [damage, frames]] {
            #expect(await frames.arm())
            #expect(await damage.arm())
            #expect(hookedIMPs() != original)
            order[0].disarm()
            order[0].disarm()
            #expect(stats.isCounting)
            order[1].disarm()
            #expect(!stats.isCounting)
            #expect(!stats.isArmed)
            await release(stats)
            #expect(hookedIMPs() == original)
        }
    }

    /// The class scan and the IMP swaps run off the main thread: the main actor stays free while the hooks
    /// go in and out, and a later arm with no class loaded since reuses the scan.
    @Test func armAndDisarmLeaveTheMainActorFreeAndASecondArmReusesTheScan() async {
        let stats = RenderStats()
        let clock = ContinuousClock()
        let armCall = clock.measure { _ = stats.arm() }
        #expect(armCall < .milliseconds(50))
        var counting = false
        let firstGap = await Self.longestMainActorGap { counting = await stats.ready() }
        #expect(counting)
        #expect(firstGap < .milliseconds(250))
        #expect(stats.fullScans == 1)
        let disarmCall = clock.measure { stats.disarm() }
        #expect(disarmCall < .milliseconds(50))
        #expect(stats.arm())
        let secondGap = await Self.longestMainActorGap { counting = await stats.ready() }
        #expect(counting)
        #expect(secondGap < .milliseconds(250))
        stats.disarm()
        #expect(stats.fullScans == 1)
        stats.forgetScan()
        #expect(await armed(stats).fullScans == 2)
        stats.disarm()
        let restoreGap = await Self.longestMainActorGap { _ = await stats.ready() }
        #expect(restoreGap < .milliseconds(250))
        await release(stats)
    }

    /// The longest the main actor went without running a job while `work` ran.
    private static func longestMainActorGap(_ work: () async -> Void) async -> Duration {
        let clock = ContinuousClock()
        let watcher = Task { @MainActor in
            var longest: Duration = .zero
            var last = clock.now
            while !Task.isCancelled {
                await Task.yield()
                let now = clock.now
                longest = max(longest, last.duration(to: now))
                last = now
            }
            return longest
        }
        await work()
        watcher.cancel()
        return await watcher.value
    }

    @Test func threeFrameSetsCountThreeAndAnEqualSetCountsZero() async {
        let view: NSView = PlainView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        let stats = await armed()
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
        await release(stats)
    }

    /// An override that calls `super` is one set, counted at the override's class.
    @Test func anOverrideCallingSuperCountsOnce() async {
        let view: NSView = SuperCallingView(frame: .zero)
        let stats = await armed()
        for side in [10.0, 20.0, 30.0] { view.setFrameSize(NSSize(width: side, height: side)) }
        #expect(count(stats, .frameSets, owner: SuperCallingView.self) == 3)
        #expect(stats.totals[.frameSets] == 3)
        await release(stats)
    }

    /// A rect from bad layout math (NaN, infinite) counts as a rect with no area and does not trap.
    @Test func updateLayerAndDrawCountDamageRectsAndArea() async {
        let view: NSView = DrawingView(frame: NSRect(x: 0, y: 0, width: 10, height: 20))
        let stats = await armed()
        view.updateLayer()
        view.draw(NSRect(x: 0, y: 0, width: 5, height: 4))
        view.draw(NSRect(x: 0, y: 0, width: CGFloat.nan, height: 4))
        view.draw(NSRect(x: 0, y: 0, width: CGFloat.infinity, height: 4))
        #expect(count(stats, .damageRects, owner: DrawingView.self) == 4)
        #expect(count(stats, .damageArea, owner: DrawingView.self) == 200 + 20)
        await release(stats)
    }

    @Test func damageAreaIsZeroForBadSizesAndClampsHugeOnes() {
        #expect(RenderStats.damageArea(width: 5, height: 4) == 20)
        #expect(RenderStats.damageArea(width: .nan, height: 4) == 0)
        #expect(RenderStats.damageArea(width: .infinity, height: 4) == 0)
        #expect(RenderStats.damageArea(width: -5, height: 4) == 0)
        #expect(RenderStats.damageArea(width: 1e300, height: 1e300) == 0) // infinite
        #expect(RenderStats.damageArea(width: 1e10, height: 1e10) == Int.max)
    }

    /// A view that does not draw keeps NSView's `drawRect:` while armed, so AppKit treats it as disarmed:
    /// a display pass leaves its layer contents as they are with the hooks out.
    @Test func aViewThatDoesNotDrawDisplaysAsWhenDisarmed() async {
        let disarmed = Self.hasContentsAfterDisplay(DisarmedBackedView(frame: NSRect(x: 0, y: 0, width: 40, height: 40)))
        let stats = await armed()
        #expect(class_getMethodImplementation(ArmedBackedView.self, #selector(NSView.draw(_:)))
            == class_getMethodImplementation(NSView.self, #selector(NSView.draw(_:))))
        #expect(Self.hasContentsAfterDisplay(ArmedBackedView(frame: NSRect(x: 0, y: 0, width: 40, height: 40))) == disarmed)
        await release(stats)
    }

    private static func hasContentsAfterDisplay(_ view: NSView) -> Bool {
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        view.wantsLayer = true
        window.contentView = view
        view.needsDisplay = true
        view.displayIfNeeded()
        let hasContents = view.layer?.contents != nil
        window.contentView = nil
        return hasContents
    }

    @Test func trackingAreaAddsCount() async {
        let view: NSView = PlainView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        let stats = await armed()
        view.addTrackingArea(NSTrackingArea(rect: view.bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: view))
        #expect(count(stats, .trackingAreaAdds, owner: PlainView.self) == 1)
        await release(stats)
    }

    @Test func windowCallsCountOnlyChanges() async {
        let window: NSWindow = ProbeWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.borderless],
                                 backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let stats = await armed()
        window.setFrame(NSRect(x: 10, y: 10, width: 300, height: 120), display: false)
        window.setFrame(window.frame, display: false)
        window.alphaValue = 0.5
        window.alphaValue = 0.5
        #expect(count(stats, .windowCalls, owner: ProbeWindow.self) == 2)
        await release(stats)
    }

    /// Renderer threads set layer contents: every change counts, a repeat of the same object does not, and the
    /// counters take it without a data race (run under TSan: `swift test --sanitize=thread`).
    @Test func contentsSetsFromBackgroundThreadsCountWithoutARace() async {
        let stats = await armed()
        let (offMain, sets) = await Self.setContentsOffMain(threads: 8, setsPerThread: 50)
        #expect(offMain == 8)
        #expect(sets == 8 * 50)
        #expect(count(stats, .contentsSets, owner: ProbeLayer.self) == sets)
        await release(stats)
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

    /// A `setContents:` a layer class gains at runtime (TypingFrameProbe's), added while disarmed or while
    /// armed, counts once at the hook it reaches; after disarm it reaches CALayer's own IMP, and a later
    /// arm counts it again (it never kept an old hook).
    @Test func aMethodAddedAtRuntimeCountsThroughTheHookItReaches() async {
        let rootIMP = class_getMethodImplementation(CALayer.self, Self.setContents)
        Self.addForwardingSetContents(to: AddedWhileDisarmedLayer.self)
        let stats = await armed()
        Self.addForwardingSetContents(to: AddedWhileArmedLayer.self)
        let early = AddedWhileDisarmedLayer()
        early.contents = Self.image(gray: 0)
        early.contents = Self.image(gray: 1)
        let late = AddedWhileArmedLayer()
        late.contents = Self.image(gray: 0)
        late.contents = Self.image(gray: 1)
        #expect(count(stats, .contentsSets, owner: AddedWhileDisarmedLayer.self) == 2)
        #expect(count(stats, .contentsSets, owner: AddedWhileArmedLayer.self) == 2)
        #expect(stats.owners().filter { $0.name.contains("AddedWhile") }.count == 2)
        await release(stats)
        #expect(class_getMethodImplementation(CALayer.self, Self.setContents) == rootIMP)

        let again = await armed()
        late.contents = Self.image(gray: 0)
        #expect(count(again, .contentsSets, owner: AddedWhileArmedLayer.self) == 1)
        await release(again)
    }

    /// Adds `setContents:` to `type` as TypingFrameProbe does: it calls its superclass's IMP as it is at the call.
    private static func addForwardingSetContents(to type: AnyClass) {
        let selector = setContents
        guard let superclass = class_getSuperclass(type), let inherited = class_getInstanceMethod(superclass, selector) else { return }
        let block: @convention(block) (AnyObject, AnyObject?) -> Void = { layer, contents in
            if let imp = class_getMethodImplementation(superclass, selector) {
                unsafeBitCast(imp, to: SetContents.self)(layer, selector, contents)
            }
        }
        class_addMethod(type, selector, imp_implementationWithBlock(block), method_getTypeEncoding(inherited))
    }

    @Test func armingRoutesLayoutPassGuardLayoutCalls() async {
        let guardian = LayoutPassGuard.shared
        let stats = await armed(RenderStats(layoutGuard: guardian))
        #expect(guardian.renderStats === stats)
        stats.recordLayout(of: PlainView.self)
        #expect(count(stats, .layouts, owner: PlainView.self) == 1)
        stats.disarm()
        #expect(guardian.renderStats == nil)
        stats.recordLayout(of: PlainView.self)
        #expect(count(stats, .layouts, owner: PlainView.self) == 1)
        await release(stats)
    }

    /// Owners past the table's capacity still count, in the overflow cell, and the totals stay whole.
    @Test func ownersPastCapacityGoToTheOverflowCell() async {
        let stats = await armed(RenderStats(ownerCapacity: 1))
        stats.recordLayout(of: PlainView.self)
        stats.recordLayout(of: DrawingView.self)
        stats.recordLayout(of: DrawingView.self)
        #expect(stats.totals[.layouts] == 3)
        #expect(stats.owners().map(\.totals[.layouts]).sorted() == [1, 2])
        stats.reset()
        #expect(stats.totals == RenderStats.Totals())
        #expect(stats.owners().isEmpty)
        await release(stats)
    }

    /// Per recorded frame, the counts since the previous tick (the first tick only marks); the owner counts
    /// cover the same frames as the sums, and both stay readable after the arm ends, until `clear()`.
    @Test func renderFrameLogKeepsCountsPerRecordedFrame() async {
        let stats = RenderStats()
        let log = RenderFrameLog(stats: stats, windows: { [] })
        #expect(Array(log.report(raw: true).keys) == ["render_armed"])
        #expect(await log.arm())
        log.clear()
        stats.recordLayout(of: PlainView.self) // before the first tick: outside the frames
        log.tick(record: false)
        stats.recordLayout(of: PlainView.self)
        stats.recordLayout(of: PlainView.self)
        log.tick(record: true)
        stats.recordLayout(of: DrawingView.self)
        log.tick(record: true)
        stats.recordLayout(of: PlainView.self) // after the last tick: outside the frames

        let report = log.report(raw: true)
        #expect(report["render_armed"] as? Bool == true)
        #expect(report["layouts"] as? Int == 3)
        #expect(report["layouts_max"] as? Int == 2)
        #expect(report["layouts_per_frame"] as? [Int] == [2, 1])
        #expect(report["frame_sets_per_frame"] as? [Int] == [0, 0])
        #expect(report["hidden_looping_animations"] as? Int == 0)
        let owners = Self.layoutsByOwner(report)
        #expect(owners["PlainView"] == 2)
        #expect(owners["DrawingView"] == 1)

        log.disarm()
        #expect(!stats.isCounting)
        let stopped = log.report(raw: false)
        #expect(stopped["render_armed"] as? Bool == false)
        #expect(stopped["layouts"] as? Int == 3)
        #expect(stopped["layouts_per_frame"] == nil)
        #expect(Self.layoutsByOwner(stopped) == owners)
        log.clear()
        #expect(Array(log.report(raw: false).keys) == ["render_armed"])
        await release(stats)
    }

    private static func layoutsByOwner(_ report: [String: Any]) -> [String: Int] {
        var layouts: [String: Int] = [:]
        for entry in report["render_owners"] as? [[String: Any]] ?? [] {
            if let name = entry["owner"] as? String, let count = entry["layouts"] as? Int { layouts[name] = count }
        }
        return layouts
    }

    /// A disarm while the class scan runs: the install finds no arm and puts no hook in.
    @Test func aDisarmDuringTheScanInstallsNothing() async {
        let original = hookedIMPs()
        let stats = RenderStats()
        #expect(stats.arm())
        stats.disarm()
        #expect(!(await stats.ready()))
        #expect(!stats.isArmed)
        #expect(hookedIMPs() == original)
    }

    /// A producer that presents its own frames (a terminal renderer).
    nonisolated final class PresentingProducer: NSObject {}

    /// Frames a producer presents itself, off the main thread and through no `setContents:`,
    /// count as contents sets of their owner only while the stats count, from many threads without a data race
    /// (run under TSan: `swift test --sanitize=thread`).
    @Test func presentedFramesCountAsContentsSetsOfTheirOwnerWhileCounting() async {
        let stats = RenderStats()
        await Self.present(stats.presentedFrames, threads: 4, framesPerThread: 10)
        #expect(count(stats, .contentsSets, owner: PresentingProducer.self) == 0, "not armed: nothing counts")
        _ = await armed(stats)
        await Self.present(stats.presentedFrames, threads: 8, framesPerThread: 50)
        #expect(count(stats, .contentsSets, owner: PresentingProducer.self) == 8 * 50)
        await release(stats)
        await Self.present(stats.presentedFrames, threads: 4, framesPerThread: 10)
        #expect(count(stats, .contentsSets, owner: PresentingProducer.self) == 8 * 50, "disarmed: nothing more counts")
    }

    /// `threads` threads off the main thread each present `framesPerThread` frames of a ``PresentingProducer``.
    nonisolated static func present(_ frames: RenderStats.PresentedFrames, threads: Int, framesPerThread: Int) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                DispatchQueue.concurrentPerform(iterations: threads) { _ in
                    for _ in 0..<framesPerThread { frames.framePresented(by: PresentingProducer.self) }
                }
                continuation.resume()
            }
        }
    }
    #endif

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

    #if !(DEBUG || CMUX_BENCH_HOOKS)
    @Test func releaseBuildsHaveNoHooks() async {
        let stats = RenderStats()
        #expect(!RenderStats.isAvailable)
        #expect(!stats.arm())
        #expect(!stats.isArmed)
        #expect(!(await stats.ready()))
        let log = RenderFrameLog(stats: stats, windows: { [] })
        #expect(!(await log.arm()))
        #expect(Array(log.report(raw: true).keys) == ["render_armed"])
    }
    #endif
}

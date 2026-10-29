public import AppKit
import CmuxNextCompat
import ObjectiveC
import QuartzCore

/// Render work counted per owner class while a counting bench is armed:
/// view frame sets, `layout()` calls, `updateLayer`/`draw(_:)` damage (rects
/// and area in points), layer contents sets, window-server calls
/// (`-[NSWindow setFrame:display:]`, `setAlphaValue:`) and tracking-area adds.
///
/// Chrome's model: `cc::RenderingStatsInstrumentation`
/// (cc/debug/rendering_stats_instrumentation.cc) records per-frame counts only
/// while `record_rendering_stats` is on, and `cc::DamageTracker`
/// (cc/trees/damage_tracker.cc) names the layers that damaged a frame. Here the
/// hooks exist only in `DEBUG || CMUX_BENCH_HOOKS` builds and are installed only
/// while armed; ``disarm()`` puts every original IMP back. In Release ``arm()``
/// returns false and no hook is compiled.
///
/// Method IMPs are process-wide, so the app has one instance: the composition
/// root (AppControl) makes it and passes it to every probe (`debug.frames`,
/// `debug.damage`), whose arms nest on it.
///
/// The hooks go in and out off the main thread: ``arm()`` starts the class
/// scan (kept while the runtime's class count stays the same) and the IMP
/// swaps (each flushes method caches: about 0.8 s for all, on the fleet in
/// Debug), and ``ready()`` waits for them; ``disarm()`` stops the counting at
/// once and queues the swaps back. Each method is hooked on its root class
/// (`NSView`, `CALayer`, `NSWindow`) and on every subclass that defines its
/// own, except `drawRect:` and `updateLayer`, which are hooked on
/// subclasses only: a view that does not override them keeps NSView's own IMP,
/// which AppKit reads to decide whether the view gets a backing store.
///
/// A call counts once, at the receiver's most derived hooked class: an override
/// that calls `super` is not counted twice, and a method added at runtime that
/// calls its superclass's IMP at call time (TypingFrameProbe) counts at the hook
/// it reaches. A set that does not change the value (an equal frame, size,
/// origin, alpha or the same contents object) counts 0. Counters are lock-free
/// atomics, so a contents set from a renderer thread counts without a race;
/// frame, window and `updateLayer` calls count on the main thread only (they
/// read view state). One `-[NSView setFrame:]` that moves and resizes counts 2
/// (AppKit sends `setFrameOrigin:` and `setFrameSize:`).
///
/// A producer that presents its frames itself, off the main thread and through no
/// `setContents:` (a terminal's renderer with renderer-owned frames),
/// counts each shown frame as a contents set of its owner
/// through ``presentedFrames``, from the thread its presentation feedback runs
/// on, as Chrome counts a frame at its presentation feedback
/// (`viz::Display::DidReceivePresentationFeedback`, components/viz/service/display/display.cc).
@MainActor
public final class RenderStats {
    public nonisolated enum Counter: Int, CaseIterable, Sendable {
        case frameSets, layouts, damageRects, damageArea, contentsSets, windowCalls, trackingAreaAdds

        /// The `debug.frames` / `debug.damage` key.
        public var key: String {
            switch self {
            case .frameSets: "frame_sets"
            case .layouts: "layouts"
            case .damageRects: "damage_rects"
            case .damageArea: "damage_area"
            case .contentsSets: "contents_sets"
            case .windowCalls: "window_calls"
            case .trackingAreaAdds: "tracking_area_adds"
            }
        }
    }

    /// One value per ``Counter``.
    public nonisolated struct Totals: Sendable, Equatable {
        public private(set) var values = [Int](repeating: 0, count: Counter.allCases.count)

        public init() {}

        public subscript(counter: Counter) -> Int {
            get { values[counter.rawValue] }
            set { values[counter.rawValue] = newValue }
        }

        /// Calls of every counter but the damage area.
        public var calls: Int { Counter.allCases.reduce(0) { $1 == .damageArea ? $0 : $0 &+ self[$1] } }

        public static func - (lhs: Totals, rhs: Totals) -> Totals {
            var result = Totals()
            for counter in Counter.allCases { result[counter] = lhs[counter] &- rhs[counter] }
            return result
        }
    }

    public nonisolated struct Owner: Sendable, Equatable {
        /// The owner class's ``RenderStats/classKey(_:)``.
        public var key: UInt
        public var name: String
        public var totals: Totals
    }

    /// Whether this build has the hooks (`DEBUG || CMUX_BENCH_HOOKS`).
    public static var isAvailable: Bool {
        #if DEBUG || CMUX_BENCH_HOOKS
        true
        #else
        false
        #endif
    }

    /// Someone holds an ``arm()``.
    public var isArmed: Bool { armers > 0 }
    /// This instance's hooks are installed and counting.
    public private(set) var isCounting = false
    private var armers = 0
    nonisolated let ledger: Ledger
    /// Where producers that present off the main thread count their frames (``PresentedFrames``).
    public nonisolated let presentedFrames: PresentedFrames
    private let layoutGuard: LayoutPassGuard?
    #if DEBUG || CMUX_BENCH_HOOKS
    var hooks = HookSet()
    /// The last install or restore queued; each waits for the one before it.
    private var hookWork: Task<Void, Never>?
    /// The last class scan, kept while the runtime's class count stays the same.
    private var lastScan: ClassScan?
    /// How many full class scans ran (a scan the class count let pass is not one).
    private(set) var fullScans = 0
    #endif

    /// `layoutGuard` counts `layout()` calls while armed (it hooks `-[NSView layout]` for the app already).
    public init(layoutGuard: LayoutPassGuard? = nil, ownerCapacity: Int = 512) {
        self.layoutGuard = layoutGuard
        ledger = Ledger(capacity: ownerCapacity)
        presentedFrames = PresentedFrames(ledger: ledger)
    }

    /// Holds one arm; arms nest (`debug.frames` and `debug.damage` can both
    /// hold one). The first queues the install, which clears the counts;
    /// ``ready()`` waits for it. Returns false, and holds nothing, in a build
    /// without hooks.
    @discardableResult
    public func arm() -> Bool {
        #if DEBUG || CMUX_BENCH_HOOKS
        armers += 1
        if armers == 1 { queueHookWork { await $0.install() } }
        return true
        #else
        return false
        #endif
    }

    /// Waits for the hook work queued so far; true when this instance counts.
    public func ready() async -> Bool {
        #if DEBUG || CMUX_BENCH_HOOKS
        await hookWork?.value
        #endif
        return isCounting
    }

    /// Ends one ``arm()``; the last one stops the counting and queues every original IMP back.
    public func disarm() {
        #if DEBUG || CMUX_BENCH_HOOKS
        guard armers > 0 else { return }
        armers -= 1
        guard armers == 0, isCounting else { return }
        ledger.disarm()
        isCounting = false
        if layoutGuard?.renderStats === self { layoutGuard?.renderStats = nil }
        let installed = hooks.hooks
        queueHookWork { _ in await Self.swap(installed, in: false) }
        #endif
    }

    #if DEBUG || CMUX_BENCH_HOOKS
    private func queueHookWork(_ work: @escaping @MainActor (RenderStats) async -> Void) {
        let previous = hookWork
        // main-hop-allow: debug and bench builds only: the one chain arms and disarms await in order; its scans and swaps run off main (@concurrent), its main parts only set the arm state and hook lists
        hookWork = Task {
            await previous?.value
            await work(self)
        }
    }

    /// The class scan (only when the class count changed), then the hooks,
    /// unless every arm ended meanwhile; both off the main thread.
    private func install() async {
        if let fresh = await Self.scanClasses(unlessCountIs: lastScan?.classCount) {
            lastScan = fresh
            fullScans += 1
        }
        guard armers > 0, !isCounting, let scan = lastScan else { return }
        ledger.reset()
        hooks = makeHooks(for: scan)
        let wanted = hooks.hooks
        await Self.swap(wanted, in: true)
        guard armers > 0 else { return await Self.swap(wanted, in: false) }
        ledger.arm(generation: hooks.generation)
        isCounting = true
        layoutGuard?.renderStats = self
    }

    /// Drops the kept class scan, so the next arm scans in full.
    func forgetScan() { lastScan = nil }
    #endif

    /// Clears every count (owners too).
    public func reset() { ledger.reset() }

    /// All owners summed since the install or the last ``reset()``.
    public var totals: Totals { ledger.totals() }

    /// Counts per owner class since the install or the last ``reset()``, most calls first.
    public func owners() -> [Owner] {
        ledger.owners().map { Owner(key: $0.key, name: Self.name(of: $0.type), totals: $0.totals) }
            .sorted { $0.totals.calls > $1.totals.calls }
    }

    /// The counts per owner ``Owner/key`` now, without names (cheap enough for every frame).
    public func ownerTotals() -> [UInt: Totals] {
        Dictionary(ledger.owners().map { ($0.key, $0.totals) }, uniquingKeysWith: { first, _ in first })
    }

    /// `LayoutPassGuard` reports one `-[NSView layout]` call.
    func recordLayout(of type: AnyClass) {
        ledger.add(.layouts, owner: type)
    }

    /// A class's one identity here: its Objective-C class object, the same for a
    /// Swift metatype (`NSView.self`, `type(of:)`) and a runtime class pointer.
    public nonisolated static func classKey(_ type: AnyClass) -> UInt {
        UInt(bitPattern: ObjectIdentifier(type as AnyObject))
    }

    /// Points of damage for a rect of this size; 0 for an empty, negative or
    /// non-finite size, `Int.max` past it.
    nonisolated static func damageArea(width: CGFloat, height: CGFloat) -> Int {
        let area = Double(width) * Double(height)
        guard area.isFinite, area > 0 else { return 0 }
        return area < Double(Int.max) ? Int(area.rounded()) : Int.max
    }

    /// A KVO subclass counts as the class it observes.
    static func name(of type: AnyClass) -> String {
        if NSStringFromClass(type).hasPrefix("NSKVONotifying_"), let observed = class_getSuperclass(type) {
            return String(describing: observed)
        }
        return String(describing: type)
    }

    /// Infinite-repeat Core Animation animations on layers nobody sees (the
    /// layer or an ancestor hidden or fully transparent, or its window not
    /// visible or occluded), per owner (the layer's view, else its class).
    public static func hiddenLoopingAnimations(in windows: [NSWindow]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for window in windows {
            guard let root = (window.contentView?.superview ?? window.contentView)?.layer else { continue }
            let shown = window.isVisible && window.occlusionState.contains(.visible)
            countHiddenLoops(in: root, hidden: !shown, into: &counts)
        }
        return counts
    }

    static func countHiddenLoops(in layer: CALayer, hidden: Bool, into counts: inout [String: Int]) {
        let hidden = hidden || layer.isHidden || layer.opacity == 0
        if hidden {
            let loops = (layer.animationKeys() ?? []).compactMap { layer.animation(forKey: $0) }.filter(\.loopsForever).count
            if loops > 0 {
                let owner: AnyObject = layer.delegate.map { $0 as AnyObject } ?? layer
                counts[name(of: Swift.type(of: owner)), default: 0] += loops
            }
        }
        for sublayer in layer.sublayers ?? [] { countHiddenLoops(in: sublayer, hidden: hidden, into: &counts) }
    }

    /// Lock-free counts: one cell per owner class (open addressing on its
    /// ``RenderStats/classKey(_:)``, at most ``probes`` probes, then the
    /// overflow cell) and one for all owners.
    nonisolated final class Ledger: Sendable {
        let total = Cell()
        let overflow = Cell()
        let cells: [Cell]
        /// The generation of the armed hooks; 0 while disarmed. A hook counts only while it is its own.
        private let armedGeneration = Atomic<Int>(0)
        static let probes = 16

        init(capacity: Int) {
            cells = (0..<max(1, capacity)).map { _ in Cell() }
        }

        var isArmed: Bool { armedGeneration.load(ordering: .acquiring) != 0 }

        func isArmed(generation: Int) -> Bool { armedGeneration.load(ordering: .acquiring) == generation }

        func arm(generation: Int) { armedGeneration.store(generation, ordering: .releasing) }

        func disarm() { armedGeneration.store(0, ordering: .releasing) }

        func add(_ counter: Counter, _ amount: Int = 1, owner: AnyClass) {
            guard isArmed else { return }
            total.add(counter, amount)
            cell(for: owner).add(counter, amount)
        }

        private func cell(for owner: AnyClass) -> Cell {
            let key = RenderStats.classKey(owner)
            var index = Int((key >> 4) % UInt(cells.count))
            for _ in 0..<min(Self.probes, cells.count) {
                let cell = cells[index]
                let found = cell.key.load(ordering: .acquiring)
                if found == key { return cell }
                if found == 0 {
                    let claim = cell.key.compareExchange(expected: 0, desired: key, ordering: .acquiringAndReleasing)
                    if claim.exchanged {
                        // The metatype, for the owner's name (a metatype is never freed).
                        cell.type.store(UInt(bitPattern: ObjectIdentifier(owner)), ordering: .releasing)
                        return cell
                    }
                    if claim.original == key { return cell }
                }
                index = (index + 1) % cells.count
            }
            return overflow
        }

        func totals() -> Totals { total.totals() }

        /// Owner classes with counts; the overflow cell is reported as `RenderStats.Ledger` (key `UInt.max`).
        /// A cell whose claim is still storing its metatype is left out of this read.
        func owners() -> [(key: UInt, type: AnyClass, totals: Totals)] {
            var owners: [(key: UInt, type: AnyClass, totals: Totals)] = cells.compactMap { cell in
                let key = cell.key.load(ordering: .acquiring)
                let type = cell.type.load(ordering: .acquiring)
                guard key != 0, type != 0 else { return nil }
                // SAFETY: `type` is the bits of the owner metatype `cell(for:)` stored (nonzero, checked above), and a
                // metatype is never freed, so they name a live class.
                return unsafe (key, unsafeBitCast(type, to: AnyClass.self), cell.totals())
            }
            let spill = overflow.totals()
            if spill != Totals() { owners.append((key: UInt.max, type: Ledger.self, totals: spill)) }
            return owners
        }

        func reset() {
            total.clear()
            overflow.clear()
            for cell in cells { cell.clear() }
        }
    }

    nonisolated final class Cell: Sendable {
        let key = Atomic<UInt>(0)
        let type = Atomic<UInt>(0)
        private let frameSets = Atomic<Int>(0)
        private let layouts = Atomic<Int>(0)
        private let damageRects = Atomic<Int>(0)
        private let damageArea = Atomic<Int>(0)
        private let contentsSets = Atomic<Int>(0)
        private let windowCalls = Atomic<Int>(0)
        private let trackingAreaAdds = Atomic<Int>(0)

        func add(_ counter: Counter, _ amount: Int) {
            with(counter) { _ = $0.add(amount, ordering: .relaxed) }
        }

        func totals() -> Totals {
            var totals = Totals()
            for counter in Counter.allCases { totals[counter] = with(counter) { $0.load(ordering: .relaxed) } }
            return totals
        }

        func clear() {
            for counter in Counter.allCases { with(counter) { $0.store(0, ordering: .relaxed) } }
            type.store(0, ordering: .relaxed)
            key.store(0, ordering: .releasing)
        }

        private func with<R>(_ counter: Counter, _ body: (borrowing Atomic<Int>) -> R) -> R {
            switch counter {
            case .frameSets: body(frameSets)
            case .layouts: body(layouts)
            case .damageRects: body(damageRects)
            case .damageArea: body(damageArea)
            case .contentsSets: body(contentsSets)
            case .windowCalls: body(windowCalls)
            case .trackingAreaAdds: body(trackingAreaAdds)
            }
        }
    }
}

extension CAAnimation {
    var loopsForever: Bool {
        repeatCount >= .greatestFiniteMagnitude || repeatDuration >= .greatestFiniteMagnitude
    }
}

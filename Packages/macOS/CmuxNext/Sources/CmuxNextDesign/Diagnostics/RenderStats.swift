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
/// while armed (``arm()``, `debug.frames` with `render: true`, `debug.damage`);
/// ``disarm()`` puts every original IMP back. In Release ``arm()`` returns false
/// and no hook is compiled.
///
/// Each hooked method is replaced on the root class (`NSView`, `CALayer`,
/// `NSWindow`) and on every loaded subclass that defines its own, and a call
/// counts once, at the receiver's most derived hooked class: an override that
/// calls `super` is not counted twice. A set that does not change the value
/// (an equal frame, size, origin, alpha or the same contents object) counts 0.
/// Counters are lock-free atomics, so a contents set from a renderer thread
/// counts without a race; frame, window and `updateLayer` calls count on the
/// main thread only (they read view state). Classes loaded after the first
/// ``arm()`` count at their nearest hooked superclass.
@MainActor
public final class RenderStats {
    public enum Counter: Int, CaseIterable, Sendable {
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
    public struct Totals: Sendable, Equatable {
        public private(set) var values = [Int](repeating: 0, count: Counter.allCases.count)

        public init() {}

        public subscript(counter: Counter) -> Int {
            get { values[counter.rawValue] }
            set { values[counter.rawValue] = newValue }
        }

        /// Calls of every counter but the damage area.
        public var calls: Int { Counter.allCases.reduce(0) { $1 == .damageArea ? $0 : $0 + self[$1] } }

        public static func - (lhs: Totals, rhs: Totals) -> Totals {
            var result = Totals()
            for counter in Counter.allCases { result[counter] = lhs[counter] &- rhs[counter] }
            return result
        }
    }

    public struct Owner: Sendable, Equatable {
        public var id: ObjectIdentifier
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

    public var isArmed: Bool { armers > 0 }
    private var armers = 0
    nonisolated let ledger: Ledger
    private let layoutGuard: LayoutPassGuard?
    #if DEBUG || CMUX_BENCH_HOOKS
    private var hooks: [Hook]?
    #endif

    /// `layoutGuard` counts `layout()` calls while armed (it hooks `-[NSView layout]` for the app already).
    public init(layoutGuard: LayoutPassGuard? = nil, ownerCapacity: Int = 512) {
        self.layoutGuard = layoutGuard
        ledger = Ledger(capacity: ownerCapacity)
    }

    /// Starts counting; armers nest (`debug.frames` and `debug.damage` can both
    /// hold it). The first arm clears the counts and installs the hooks.
    /// Returns false in a build without hooks.
    @discardableResult
    public func arm() -> Bool {
        #if DEBUG || CMUX_BENCH_HOOKS
        armers += 1
        guard armers == 1 else { return true }
        ledger.reset()
        ledger.isArmed = true
        let hooks = hooks ?? Self.buildHooks(ledger: ledger)
        self.hooks = hooks
        for hook in hooks { method_setImplementation(hook.method, hook.replacement) }
        layoutGuard?.renderStats = self
        return true
        #else
        return false
        #endif
    }

    /// Ends one ``arm()``; the last one puts every original IMP back.
    public func disarm() {
        #if DEBUG || CMUX_BENCH_HOOKS
        guard armers > 0 else { return }
        armers -= 1
        guard armers == 0 else { return }
        ledger.isArmed = false
        // A hook another swizzler chained onto stays and forwards (its armed check fails).
        for hook in hooks ?? [] where method_getImplementation(hook.method) == hook.replacement {
            method_setImplementation(hook.method, hook.original)
        }
        if layoutGuard?.renderStats === self { layoutGuard?.renderStats = nil }
        #endif
    }

    /// Clears every count (owners too).
    public func reset() { ledger.reset() }

    /// All owners summed since the first arm or the last ``reset()``.
    public var totals: Totals { ledger.totals() }

    /// Counts per owner class since the first arm or the last ``reset()``, most calls first.
    public func owners() -> [Owner] {
        ledger.owners().map { Owner(id: ObjectIdentifier($0.type), name: Self.name(of: $0.type), totals: $0.totals) }
            .sorted { $0.totals.calls > $1.totals.calls }
    }

    /// `LayoutPassGuard` reports one `-[NSView layout]` call.
    func recordLayout(of type: AnyClass) {
        ledger.add(.layouts, owner: type)
    }

    /// A KVO subclass counts as the class it observes.
    static func name(of type: AnyClass) -> String {
        if String(cString: class_getName(type)).hasPrefix("NSKVONotifying_"), let observed = class_getSuperclass(type) {
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

    /// Lock-free counts: one cell per owner class (open addressing on the
    /// class pointer, at most ``probes`` probes, then the overflow cell) and
    /// one for all owners.
    nonisolated final class Ledger: Sendable {
        let total = Cell()
        let overflow = Cell()
        let cells: [Cell]
        private let armed = Atomic<Bool>(false)
        static let probes = 16

        init(capacity: Int) {
            cells = (0..<max(1, capacity)).map { _ in Cell() }
        }

        var isArmed: Bool {
            get { armed.load(ordering: .acquiring) }
            set { armed.store(newValue, ordering: .releasing) }
        }

        func add(_ counter: Counter, _ amount: Int = 1, owner: AnyClass) {
            guard isArmed else { return }
            total.add(counter, amount)
            cell(for: owner).add(counter, amount)
        }

        private func cell(for owner: AnyClass) -> Cell {
            let key = UInt(bitPattern: ObjectIdentifier(owner))
            var index = Int((key >> 4) % UInt(cells.count))
            for _ in 0..<min(Self.probes, cells.count) {
                let cell = cells[index]
                let found = cell.key.load(ordering: .acquiring)
                if found == key { return cell }
                if found == 0 {
                    let claim = cell.key.compareExchange(expected: 0, desired: key, ordering: .acquiringAndReleasing)
                    if claim.exchanged || claim.original == key { return cell }
                }
                index = (index + 1) % cells.count
            }
            return overflow
        }

        func totals() -> Totals { total.totals() }

        /// Owner classes with counts; the overflow cell is reported as `RenderStats.Ledger`.
        func owners() -> [(type: AnyClass, totals: Totals)] {
            var owners: [(type: AnyClass, totals: Totals)] = cells.compactMap { cell in
                let key = cell.key.load(ordering: .acquiring)
                guard key != 0 else { return nil }
                return (unsafeBitCast(key, to: AnyClass.self), cell.totals())
            }
            let spill = overflow.totals()
            if spill != Totals() { owners.append((type: Ledger.self as AnyClass, totals: spill)) }
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

private extension CAAnimation {
    var loopsForever: Bool {
        repeatCount >= .greatestFiniteMagnitude || repeatDuration >= .greatestFiniteMagnitude
    }
}

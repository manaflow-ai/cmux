#if DEBUG || CMUX_BENCH_HOOKS
public import AppKit
import CmuxNextCompat
import Darwin
import ObjectiveC
import QuartzCore

/// Which views an input turn dirties (p04-input-093, MQ-input-dirty-views): while installed, every
/// `needsDisplay`, `setNeedsDisplay(_:)`, `needsLayout` and `needsUpdateConstraints` set on an
/// `NSView`, and every `setNeedsDisplay`, `setNeedsDisplay(_:)` and `setNeedsLayout` on a
/// `CALayer`, made on the main thread during an input's dispatch or before that pass's frame
/// commit, is recorded with the view's class, the call's return addresses and where the view lies
/// against the event's target: in its subtree, outside it, in another window. A key that dirties a
/// view outside its target is work the frame the person waits for did not need.
///
/// Chrome's model: DevTools invalidation tracking. Blink records each layout and paint
/// invalidation with its node, reason and stack only while the disabled-by-default category
/// `devtools.timeline.invalidationTracking` is on
/// (third_party/blink/renderer/core/inspector/inspector_trace_events.h,
/// `inspector_layout_invalidation_tracking_event`); here the hooks exist only in
/// `DEBUG || CMUX_BENCH_HOOKS` builds and only between ``install()`` and ``remove()``.
///
/// Bounds: at most ``siteLimit`` sites (a site is a view class, a layer class, a placement and a
/// stack; later new sites only count in ``Report/droppedCalls``) and the last ``turnLimit`` turns.
/// The hooks capture return addresses only; names are resolved off the main thread in
/// ``report(limit:)``. A call off the main thread, a clearing set (`needsDisplay = false`) and a
/// call nested in another hooked call (AppKit's own fan-out) pass through unrecorded.
///
/// The composition root makes one recorder (IMPs are process-wide) and hands it to the input tap,
/// which wraps each dispatch in ``dispatching(_:_:)``, and to `debug.input dirty`, which calls
/// ``install()``, ``report(limit:)`` and, on `debug.input reset`, ``remove()``.
/// `scripts/cmux-next/input-dirty-views.py` drives it during the real-HID typing bench.
@MainActor
public final class InputDirtyRecorder {
    /// The most distinct sites kept.
    public nonisolated static let siteLimit = 256
    /// The most closed turns kept.
    public nonisolated static let turnLimit = 64
    /// The most return addresses kept per site (the hook's own frames included).
    nonisolated static let stackDepth = 24

    /// Whether the hooks are in.
    public private(set) var isInstalled = false

    private let now: @MainActor () -> UInt64
    /// Bumped by every install and remove: a hook of an older install passes through.
    private(set) var generation = 0
    private var hooks: [InputDirtyHook.Installed] = []
    private var observers: [MainRunLoopObserver] = []
    private var turn: OpenTurn?
    private var turnSerial = 0
    /// Hooked calls running on the main thread now (a nested one is AppKit's fan-out).
    private var nesting = 0
    private var sites: [Site] = []
    private var siteIndex: [SiteKey: Int] = [:]
    /// ``stackDepth`` addresses per site, by site index.
    private var stacks: [UInt] = []
    private var droppedCalls = 0
    private var dirtyCalls = 0
    private var offTargetCalls = 0
    private var turnRing: [TurnRecord] = []
    private var turnsClosed = 0

    /// A recorder on the uptime clock.
    public convenience init() {
        self.init(now: { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) })
    }

    /// A recorder on `now` (nanoseconds, read on the main thread; tests pass a manual clock).
    init(now: @escaping @MainActor () -> UInt64) {
        self.now = now
    }

    // MARK: install and remove

    /// Puts the hooks in and starts recording turns; a second call does nothing. The tables are
    /// allocated here, at their bounds, so recording a call allocates nothing.
    public func install() {
        guard !isInstalled else { return }
        generation += 1
        isInstalled = true
        resetTables()
        hooks = InputDirtyHook.install(recorder: self, generation: generation)
        observers = [
            MainRunLoopObserver(activities: .beforeWaiting, order: .min) { [weak self] _ in self?.commitWillRun() },
            MainRunLoopObserver(activities: .beforeWaiting, order: .max) { [weak self] _ in self?.commitDidRun() },
        ]
    }

    /// Takes the hooks out (where no other swizzler chained onto them; a chained hook of this
    /// install passes through from now on) and drops what was recorded.
    public func remove() {
        guard isInstalled else { return }
        generation += 1
        isInstalled = false
        InputDirtyHook.uninstall(hooks)
        hooks = []
        observers.forEach { $0.invalidate() }
        observers = []
        turn = nil
        nesting = 0
        sites = []
        siteIndex = [:]
        stacks = []
        turnRing = []
    }

    private func resetTables() {
        sites = []
        sites.reserveCapacity(Self.siteLimit)
        siteIndex = [:]
        siteIndex.reserveCapacity(Self.siteLimit)
        stacks = [UInt](repeating: 0, count: Self.siteLimit * Self.stackDepth)
        turnRing = []
        turnRing.reserveCapacity(Self.turnLimit)
        droppedCalls = 0
        dirtyCalls = 0
        offTargetCalls = 0
        turnsClosed = 0
        turn = nil
    }

    // MARK: turns

    /// Runs `dispatch` (the event's dispatch) as part of an input turn: from here to the end of
    /// the run-loop pass that commits its frame. When not installed, or for an event that is not
    /// a person's input, it only runs `dispatch`.
    public func dispatching(_ event: NSEvent, _ dispatch: () -> Void) {
        guard isInstalled, let kind = TurnKind(event.type) else { return dispatch() }
        beginDispatch(kind, target: Self.target(of: event, kind: kind))
        defer { endDispatch() }
        dispatch()
    }

    /// The view an event goes to: the key window's first responder for keys, the view under the
    /// pointer for pointer, scroll and gesture events.
    static func target(of event: NSEvent, kind: TurnKind) -> NSView? {
        guard let window = event.window else { return nil }
        if kind == .key { return window.firstResponder as? NSView }
        // The frame view (the content view's superview) takes window coordinates.
        guard let root = window.contentView?.superview ?? window.contentView else { return nil }
        return root.hitTest(event.locationInWindow)
    }

    /// A dispatch starts: opens a turn, or joins the open one (more events before the commit).
    func beginDispatch(_ kind: TurnKind, target: NSView?) {
        if turn == nil {
            turnSerial += 1
            turn = OpenTurn(serial: turnSerial, began: now())
        }
        turn?.kinds |= kind.bit
        turn?.events += 1
        turn?.depth += 1
        turn?.target = target
    }

    /// A dispatch ends; the outermost one stamps the dispatch's end.
    func endDispatch() {
        guard var open = turn, open.depth > 0 else { return }
        open.depth -= 1
        if open.depth == 0 { open.dispatchEnded = now() }
        turn = open
    }

    /// The first `.beforeWaiting` observer of a pass: the display cycle and the frame's commit start.
    func commitWillRun() {
        guard var open = turn, open.depth == 0, open.commitBegan == 0 else { return }
        open.commitBegan = now()
        turn = open
    }

    /// The last `.beforeWaiting` observer of a pass, after Core Animation's commit: closes the turn
    /// (not while a dispatch still runs, as in a nested tracking loop).
    func commitDidRun() {
        guard let open = turn, open.depth == 0 else { return }
        let end = now()
        let record = TurnRecord(
            kinds: open.kinds,
            events: open.events,
            dispatchNanos: open.dispatchEnded &- open.began,
            commitNanos: open.commitBegan == 0 ? 0 : end &- open.commitBegan,
            dirtyCalls: open.dirtyCalls,
            offTargetCalls: open.offTargetCalls
        )
        if turnRing.count < Self.turnLimit {
            turnRing.append(record)
        } else {
            turnRing[turnsClosed % Self.turnLimit] = record
        }
        turnsClosed += 1
        turn = nil
        // No hooked call runs across a run-loop observer: one that raised past its hook ends here.
        nesting = 0
    }

    // MARK: recording (the hooks' main-thread side)

    /// A hooked call of `kind` on `object` starts. True when the hook must call ``leave()`` after
    /// the original: the call belongs to an open turn of this install.
    func enter(_ kind: DirtyKind, _ object: AnyObject, generation: Int) -> Bool {
        guard generation == self.generation, turn != nil else { return false }
        nesting += 1
        if nesting == 1 { capture(kind, object) }
        return true
    }

    /// A hooked call that ``enter(_:_:generation:)`` let through returned.
    func leave() {
        if nesting > 0 { nesting -= 1 }
    }

    private func capture(_ kind: DirtyKind, _ object: AnyObject) {
        let owner = Owner(object, target: turn?.target)
        withUnsafeTemporaryAllocation(of: UInt.self, capacity: Self.stackDepth) { buffer in
            guard let base = buffer.baseAddress else { return }
            let found = base.withMemoryRebound(to: UnsafeMutableRawPointer?.self, capacity: Self.stackDepth) {
                Int(backtrace($0, Int32(Self.stackDepth)))
            }
            record(kind, owner: owner, stack: UnsafeBufferPointer(start: base, count: max(0, found)))
        }
    }

    /// Counts one dirty call of the open turn at its site. Allocates nothing: the tables were
    /// reserved at their bounds by ``install()``.
    func record(_ kind: DirtyKind, owner: Owner, stack: UnsafeBufferPointer<UInt>) {
        guard var open = turn else { return }
        let offTarget = owner.placement.isOffTarget
        open.dirtyCalls += 1
        if offTarget { open.offTargetCalls += 1 }
        turn = open
        dirtyCalls += 1
        if offTarget { offTargetCalls += 1 }
        var hasher = Hasher()
        for address in stack { hasher.combine(address) }
        let key = SiteKey(viewClass: owner.viewClass, layerClass: owner.layerClass, placement: owner.placement,
                          stackHash: hasher.finalize())
        let phase: UInt8 = open.depth > 0 ? Phase.dispatch.bit : Phase.commit.bit
        if let index = siteIndex[key] {
            sites[index].count += 1
            sites[index].kinds |= kind.bit
            sites[index].turnKinds |= open.kinds
            sites[index].phases |= phase
            if sites[index].lastTurn != open.serial {
                sites[index].lastTurn = open.serial
                sites[index].turns += 1
            }
            return
        }
        guard sites.count < Self.siteLimit else {
            droppedCalls += 1
            return
        }
        let index = sites.count
        let kept = min(stack.count, Self.stackDepth)
        for slot in 0..<kept { stacks[index * Self.stackDepth + slot] = stack[slot] }
        sites.append(Site(key: key, kinds: kind.bit, turnKinds: open.kinds, phases: phase, count: 1, turns: 1,
                          lastTurn: open.serial, stackCount: kept))
        siteIndex[key] = index
    }

    // MARK: report

    /// What was recorded since ``install()``: the sites (off-target first, then by count; at most
    /// `limit`) with their frames resolved off the main thread, and the recent turns' timings.
    public func report(limit: Int = InputDirtyRecorder.siteLimit) async -> Report {
        let snapshot = Snapshot(
            installed: isInstalled, sites: sites, stacks: stacks, turns: turnRing, turnsClosed: turnsClosed,
            droppedCalls: droppedCalls, dirtyCalls: dirtyCalls, offTargetCalls: offTargetCalls, limit: max(0, limit)
        )
        return await Self.resolve(snapshot)
    }
}
#endif

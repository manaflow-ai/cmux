import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextCompat
import CmuxNextFocus
import Darwin
import Foundation
import Testing

/// KeyRouterBench (ported from the dogfood line's plan DC8 bench to feat-cmux-next's APIs): the real key
/// dispatcher (`KeyRouter.interceptKeyDown`, the `key-dispatch` perf-hot path, 0.5 ms and 0 allocations per key)
/// in a cmux window of a 60-workspace registry whose focused pane is a terminal, one of 30 panes. It drives
/// synthetic key-downs (a plain key, Cmd-T, Cmd-D, a when-clause binding and Ctrl-C) and prints one
/// `KEY-ROUTER-BENCH {json}` line with `plain_p99_us, chord_p99_us, plain_allocs, chord_allocs, key_equiv_views`.
///
/// Chrome's model: input latency is a distribution read from lab benchmarks, never a pass/fail timer in a unit
/// run. So this file asserts no time: the timing loop runs only with `CMUX_BENCH=1`, and the agent reads the
/// numbers. The allocation count on the calling thread (libmalloc's `malloc_logger` hook) is the only check a
/// plain unit run makes. It counts the router alone: the dispatch context around it (`InputDispatchContext`) is
/// `CmuxApplication.sendEvent`'s and opens outside the count.
///
/// When a key kind allocates, a second pass over ``traceKeys`` keys records the return addresses of every
/// allocation (into a buffer made before the pass, from inside the hook) and prints `KEY-ROUTER-ALLOC` lines:
/// the top allocating sites per key, each as the first cmux frame and the allocating leaf below it.
@MainActor @Suite(.serialized)
struct KeyRouterBench {
    /// A key-down the bench sends, before its event is made (each press needs a fresh event: the router
    /// decides a key-down once).
    private struct Key {
        let name: String
        let characters: String
        let unmodified: String
        let keyCode: UInt16
        let modifiers: NSEvent.ModifierFlags
    }

    private static let plain = Key(name: "plain_a", characters: "a", unmodified: "a", keyCode: 0, modifiers: [])
    private static let chords = [
        Key(name: "cmd_t", characters: "t", unmodified: "t", keyCode: 17, modifiers: [.command]),
        Key(name: "cmd_d", characters: "d", unmodified: "d", keyCode: 2, modifiers: [.command]),
        Key(name: "when_clause", characters: "\u{02}", unmodified: "b", keyCode: 11, modifiers: [.command, .control]),
        Key(name: "ctrl_c", characters: "\u{03}", unmodified: "c", keyCode: 8, modifiers: [.control]),
    ]
    /// The when-clause binding: a user entry that holds only in a terminal without a text field.
    private static let whenClause = WhenClause.and([.has("terminalFocused"), .not(.has(KeyContext.textInputFocus))])

    private static let workspaceCount = 60
    private static let paneCount = 30
    /// Keys run before counting or timing: lazy tables, caches and the first chunk of every buffer are made once.
    private static let warmKeys = 64
    /// Keys whose allocations are counted, per key kind.
    private static let allocationKeys = 256
    /// Keys whose allocations are traced (call sites), per key kind that allocates.
    private static let traceKeys = 32
    /// Traces kept per key kind (allocations past it are counted, not traced).
    private static let traceCapacity = 8_192
    /// Keys timed per key kind, only with CMUX_BENCH=1.
    private static let timedKeys = 5_000

    /// A cmux window over 60 workspaces, its focused pane a terminal among 30, and 30 pane-sized views that
    /// count the `performKeyEquivalent` calls AppKit's key-equivalent walk makes.
    private final class Harness {
        let services: AppServices
        let shell: NSWindow
        let probes: [KeyEquivalentProbe]
        private var timestamp: TimeInterval = 20_000
        var router: KeyRouter { services.keyRouter }

        init(services: AppServices, shell: NSWindow, probes: [KeyEquivalentProbe]) {
            self.services = services
            self.shell = shell
            self.probes = probes
        }

        func event(_ key: Key) throws -> NSEvent {
            timestamp += 0.001
            return try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: key.modifiers, timestamp: timestamp,
                                                 windowNumber: shell.windowNumber, context: nil, characters: key.characters,
                                                 charactersIgnoringModifiers: key.unmodified, isARepeat: false, keyCode: key.keyCode))
        }

        /// The router's decision for `event`, dispatched as `CmuxApplication.sendEvent` does: whether it consumed the key.
        func dispatch(_ event: NSEvent) -> Bool {
            router.dispatchingSynthetic(event) { router.interceptKeyDown(event, in: shell) }
        }

        /// ``dispatch(_:)`` with the router's allocations counted (nil without the hook) and whether it consumed the key.
        func countedDispatch(_ event: NSEvent) -> (allocations: Int?, consumed: Bool) {
            router.dispatchingSynthetic(event) { () -> (allocations: Int?, consumed: Bool) in
                var consumed = false
                let allocations = MallocProbe.allocations { consumed = router.interceptKeyDown(event, in: shell) }
                return (allocations, consumed)
            }
        }

        func close() { for controller in services.windows.controllers { controller.window?.close() } }
    }

    /// A pane-sized view that counts the key-equivalent walk's visits.
    private final class KeyEquivalentProbe: NSView {
        var visits = 0

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            visits += 1
            return super.performKeyEquivalent(with: event)
        }
    }

    private static func harness() throws -> Harness {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        services.windows.ordersWindowsIn = false
        let workspaces = (0..<workspaceCount).map { "bench-workspace-\($0)" }
        let controller = try #require(services.windows.openWindow(workspaces: workspaces))
        let shell = try #require(controller.window)
        controller.focus.send(.topology(FocusTopology(workspace: workspaces[0], panes: (0..<paneCount).map { index -> FocusTopology.Pane in
            FocusTopology.Pane(id: "bench-pane-\(index)", tabs: [.init(id: "bench-tab-\(index)", kind: .terminal)], selected: "bench-tab-\(index)")
        })))
        controller.focus.send(.focusPane("bench-pane-0", source: .keyboard))
        try #require(controller.focus.state.resolved == .terminal(pane: "bench-pane-0", tab: "bench-tab-0"))
        let content = try #require(shell.contentView)
        let probes = (0..<paneCount).map { index in
            let probe = KeyEquivalentProbe(frame: NSRect(x: CGFloat(index % 6) * 40, y: CGFloat(index / 6) * 30, width: 40, height: 30))
            content.addSubview(probe)
            return probe
        }
        let harness = Harness(services: services, shell: shell, probes: probes)
        try stubActions(in: harness, controller: controller)
        return harness
    }

    /// Cmd-T's and Cmd-D's actions run a no-op effect, so thousands of presses open no tab and split no pane
    /// (the router's own work is what is measured), and Cmd-Ctrl-B is a when-clause binding to Cmd-T's action.
    private static func stubActions(in harness: Harness, controller: WindowController) throws {
        let registry = harness.services.registry
        let router = harness.router
        let focus = controller.focus.currentState()
        let facts = router.facts(in: harness.shell, controller: controller)
        var stubbed: [ActionID] = []
        for key in chords where key.name == "cmd_t" || key.name == "cmd_d" {
            let candidate = try #require(router.candidate(for: try harness.event(key), focus: focus, facts: facts),
                                         "\(key.name) resolves to nothing in a terminal")
            guard !stubbed.contains(candidate.id) else { continue }
            registry.unbind(candidate.id)
            registry.bindEffect(candidate.id, effect: { _ in .done })
            stubbed.append(candidate.id)
        }
        let target = try #require(stubbed.first)
        let whenKey = try #require(chords.first { $0.name == "when_clause" })
        _ = KeyBindingLoader(registry).load(KeyBindingLayers(user: [
            KeyBinding(keys: [Shortcut(whenKey.unmodified, modifiers: whenKey.modifiers)], command: target, when: whenClause, source: .user),
        ]))
        let resolved = router.candidate(for: try harness.event(whenKey), focus: focus, facts: facts)
        try #require(resolved?.id == target, "the when-clause binding does not win in a terminal (\(resolved?.id.rawValue ?? "nothing"))")
    }

    @Test func keyRouterBench() throws {
        let harness = try Self.harness()
        defer { harness.close() }
        let control = MallocProbe.allocations { _ = ContiguousArray(repeating: 1, count: 64).count }
        try #require((control ?? 0) > 0, "malloc_logger saw no allocation on this thread: the probe cannot measure here")
        // What the probe itself costs around an empty body inside the dispatch context: the floor of every count.
        let floorEvent = try harness.event(Self.plain)
        let floor = harness.router.dispatchingSynthetic(floorEvent) { MallocProbe.allocations {} } ?? -1

        let timing = ProcessInfo.processInfo.environment["CMUX_BENCH"] == "1"
        let plainRow = try Self.measure(Self.plain, in: harness, timing: timing)
        var chordRows: [(Key, Row)] = []
        for key in Self.chords { chordRows.append((key, try Self.measure(key, in: harness, timing: timing))) }
        let ctrlC = try #require(Self.chords.last)
        let keyEquivalentViews = try Self.keyEquivalentViews(ctrlC, in: harness)

        let chordNanos = chordRows.flatMap { $0.1.nanos }
        let chordAllocations = chordRows.map { $0.1.allocations }.reduce(0, +)
        var report: [String: Any] = [
            "plain_p99_us": Self.percentile(plainRow.nanos, 0.99),
            "plain_p50_us": Self.percentile(plainRow.nanos, 0.5),
            "plain_max_us": Self.percentile(plainRow.nanos, 1),
            "chord_p99_us": Self.percentile(chordNanos, 0.99),
            "chord_p50_us": Self.percentile(chordNanos, 0.5),
            "chord_max_us": Self.percentile(chordNanos, 1),
            "plain_allocs": Self.perKey(plainRow.allocations, keys: Self.allocationKeys),
            "chord_allocs": Self.perKey(chordAllocations, keys: Self.allocationKeys * chordRows.count),
            "key_equiv_views": Self.perKey(keyEquivalentViews, keys: Self.allocationKeys),
            "probe_floor_allocs": floor,
            "workspaces": Self.workspaceCount,
            "panes": Self.paneCount,
            "timed": timing,
            "timed_keys": timing ? Self.timedKeys : 0,
            "alloc_keys": Self.allocationKeys,
        ]
        var keys: [String: Any] = [Self.plain.name: plainRow.json(keys: Self.allocationKeys)]
        for (key, row) in chordRows { keys[key.name] = row.json(keys: Self.allocationKeys) }
        report["keys"] = keys
        let json = String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), as: UTF8.self)
        print("KEY-ROUTER-BENCH \(json)")

        // Where the allocations come from, per key kind that allocates.
        var sites = AllocationSites()
        var summaries: [AllocationSites.Summary] = []
        for (key, row) in [(Self.plain, plainRow)] + chordRows where row.allocations > 0 {
            let traced = try Self.trace(key, in: harness)
            summaries.append(sites.summarize(key.name, traces: traced.traces, allocations: traced.allocations, keys: Self.traceKeys))
        }
        for line in sites.lines(summaries) { print(line) }

        let fields = ["plain_p99_us", "chord_p99_us", "plain_allocs", "chord_allocs", "key_equiv_views"]
        let decoded = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        for field in fields { #expect(decoded[field] != nil, "the report has no \(field)") }
        // An unoptimized build allocates where an optimized one does not (array reads go through heap-allocated
        // accessor frames, modifier-set literals build arrays): about 51 per plain key on feat-cmux-next. The zero
        // is the optimized build's rule, so a Debug run records the count as a known issue. `_isDebugAssertConfiguration`
        // is the optimization level itself; `#if DEBUG` is not (the Release suite lane also passes -DDEBUG).
        if _isDebugAssertConfiguration() {
            withKnownIssue("an unoptimized build allocates on the plain-key path; run in Release for the rule", isIntermittent: true) {
                #expect(plainRow.allocations == 0, "a plain key in a terminal made \(plainRow.allocations) allocations in \(Self.allocationKeys) keys")
            }
        } else {
            #expect(plainRow.allocations == 0, "a plain key in a terminal made \(plainRow.allocations) allocations in \(Self.allocationKeys) keys")
        }
        withKnownIssue("the chord path still allocates (signposts, KeyContext, shortcut readings)", isIntermittent: true) {
            #expect(chordAllocations == 0, "the chords made \(chordAllocations) allocations in \(Self.allocationKeys * chordRows.count) keys")
        }
    }

    /// The chord step every Cmd or Ctrl key-down takes before the router resolves it (`KeyBindingTable.step`)
    /// allocates nothing: a first key that runs, one that arms a chord, the Cmd-J leader, an armed chord's next
    /// key and an unbound key. The readings and armed keys are made before the count (feat's step takes arrays).
    @Test func chordStepAllocatesNothing() throws {
        let control = MallocProbe.allocations { _ = ContiguousArray(repeating: 1, count: 64).count }
        try #require((control ?? 0) > 0, "malloc_logger saw no allocation on this thread: the probe cannot measure here")
        let cmdK = Shortcut("k", modifiers: [.command]), x = Shortcut("x", modifiers: [])
        let table = KeyBindingTable([
            KeyBinding(keys: [Shortcut("t", modifiers: [.command])], command: "new-tab"),
            KeyBinding(keys: [cmdK, x], command: "chord"),
            KeyBinding(keys: [LeaderLayer.prefix, x], command: "leader", when: .has("browserFocused")),
            KeyBinding(keys: [Shortcut("b", modifiers: [.command, .control])], command: "scoped", when: Self.whenClause),
        ])
        let context = KeyContext(["terminalFocused": .bool(true)])
        let cases: [(String, [Shortcut], [Shortcut])] = [
            ("cmd_t", [], [Shortcut("t", modifiers: [.command])]),
            ("cmd_k", [], [cmdK]),
            ("leader", [], [LeaderLayer.prefix]),
            ("cmd_k x", [cmdK], [x]),
            ("when_clause", [], [Shortcut("b", modifiers: [.command, .control])]),
            ("unbound", [], [Shortcut("}", modifiers: [.shift, .command]), Shortcut("]", modifiers: [.shift, .command])]),
        ]
        let isRunnable: (ActionID) -> Bool = { _ in true }
        // The same loop with nothing in it is the baseline: a Debug build's for-in over a range can allocate per
        // iteration (PageRouterSubscribeEndTests, probe 5529e509), so only what the steps add counts.
        let loop = try #require(MallocProbe.allocations { for _ in 0..<Self.allocationKeys {} })
        var sites = AllocationSites()
        var summaries: [AllocationSites.Summary] = []
        for (name, keys, readings) in cases {
            let warm = table.step(after: keys, readings: readings, in: context, isRunnable: isRunnable)
            var step = warm
            let measured = try #require(MallocProbe.allocations {
                for _ in 0..<Self.allocationKeys { step = table.step(after: keys, readings: readings, in: context, isRunnable: isRunnable) }
            })
            let allocations = measured - loop
            print("KEY-ROUTER-STEP \(name): \(allocations) allocations in \(Self.allocationKeys) steps (loop alone: \(loop))")
            if allocations > 0 {
                MallocProbe.beginTracing(capacity: Self.traceCapacity)
                let traced = MallocProbe.allocations {
                    for _ in 0..<Self.traceKeys { step = table.step(after: keys, readings: readings, in: context, isRunnable: isRunnable) }
                } ?? 0
                summaries.append(sites.summarize("step \(name)", traces: MallocProbe.endTracing(), allocations: traced, keys: Self.traceKeys))
            }
            #expect(step == warm)
            // The step still builds `keys + [reading]` arrays (2 to 5 per step in Release): a known issue until it does not.
            withKnownIssue("KeyBindingTable.step still allocates its candidate sequences", isIntermittent: true) {
                #expect(allocations == 0, "\(name): the chord step made \(allocations) allocations in \(Self.allocationKeys) keys (loop alone: \(loop))")
            }
        }
        for line in sites.lines(summaries) { print(line) }
    }

    // MARK: Measuring

    /// One key kind's numbers: its timed samples (empty without CMUX_BENCH=1), its allocations over
    /// ``allocationKeys`` presses, and whether the router consumed it.
    private struct Row {
        var nanos: [UInt64] = []
        var allocations = 0
        var consumed = false

        func json(keys: Int) -> [String: Any] {
            ["p99_us": KeyRouterBench.percentile(nanos, 0.99), "p50_us": KeyRouterBench.percentile(nanos, 0.5),
             "max_us": KeyRouterBench.percentile(nanos, 1), "allocs": KeyRouterBench.perKey(allocations, keys: keys),
             "consumed": consumed]
        }
    }

    private static func measure(_ key: Key, in harness: Harness, timing: Bool) throws -> Row {
        var row = Row()
        for _ in 0..<warmKeys { try autoreleasepool { _ = harness.dispatch(try harness.event(key)) } }
        for _ in 0..<allocationKeys {
            try autoreleasepool {
                let counted = harness.countedDispatch(try harness.event(key))
                row.allocations += counted.allocations ?? 0
                row.consumed = counted.consumed
            }
        }
        guard timing else { return row }
        row.nanos.reserveCapacity(timedKeys)
        for _ in 0..<timedKeys {
            try autoreleasepool {
                let event = try harness.event(key)
                let start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
                _ = harness.dispatch(event)
                row.nanos.append(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - start)
            }
        }
        return row
    }

    /// ``traceKeys`` presses of `key` with every allocation's return addresses kept: the traces and the
    /// allocations counted over those presses (more than the traces when the buffer filled).
    private static func trace(_ key: Key, in harness: Harness) throws -> (traces: [[UInt]], allocations: Int) {
        var allocations = 0
        MallocProbe.beginTracing(capacity: traceCapacity)
        for _ in 0..<traceKeys {
            try autoreleasepool { allocations += harness.countedDispatch(try harness.event(key)).allocations ?? 0 }
        }
        return (MallocProbe.endTracing(), allocations)
    }

    /// The pane views AppKit's key-equivalent walk asks about `key` after the router passed it on, as
    /// `NSApplication.sendEvent` sends a key the router did not consume to the window first.
    private static func keyEquivalentViews(_ key: Key, in harness: Harness) throws -> Int {
        for probe in harness.probes { probe.visits = 0 }
        for _ in 0..<allocationKeys {
            try autoreleasepool {
                let event = try harness.event(key)
                if !harness.dispatch(event) { _ = harness.shell.performKeyEquivalent(with: event) }
            }
        }
        return harness.probes.map(\.visits).reduce(0, +)
    }

    /// The `fraction` quantile of `nanos` in microseconds (1: the max), or NSNull without samples, so the
    /// report keeps every field.
    nonisolated static func percentile(_ nanos: [UInt64], _ fraction: Double) -> Any {
        guard !nanos.isEmpty else { return NSNull() }
        let sorted = nanos.sorted()
        let index = min(sorted.count - 1, max(0, Int((Double(sorted.count) * fraction).rounded(.up)) - 1))
        return (Double(sorted[index]) / 10).rounded() / 100
    }

    /// `count` per key, to two decimals.
    nonisolated static func perKey(_ count: Int, keys: Int) -> Double {
        (Double(count) / Double(max(1, keys)) * 100).rounded() / 100
    }
}

/// Counts the allocations one thread makes, through libmalloc's `malloc_logger` hook (the one malloc
/// stack logging uses), as PageRouterSubscribeEndTests does. While tracing, the hook also copies each counted
/// allocation's return addresses (`backtrace(3)`, which walks frame pointers and allocates nothing) into a
/// buffer made before the pass; a flag keeps an allocation made while copying out of the count and the traces.
private nonisolated struct MallocProbe {
    typealias Logger = @convention(c) (UInt32, UInt, UInt, UInt, UInt, UInt32) -> Void

    /// `MALLOC_LOG_TYPE_ALLOCATE` (libmalloc stack_logging.h).
    static let allocateType: UInt32 = 2
    /// Return addresses kept per allocation.
    static let depth = 48
    static let count = Atomic<Int>(0)
    static let thread = Atomic<UInt64>(0)
    /// The trace buffer's address (`capacity * depth` slots), 0 while not tracing.
    static let buffer = Atomic<Int>(0)
    static let capacity = Atomic<Int>(0)
    static let traced = Atomic<Int>(0)
    /// 1 while the hook copies a trace.
    static let busy = Atomic<Int>(0)

    /// The allocations `body` makes on this thread, or nil when the hook is missing.
    static func allocations(_ body: () -> Void) -> Int? {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "malloc_logger") else { return nil }
        let slot = symbol.assumingMemoryBound(to: Logger?.self)
        var id: UInt64 = 0
        pthread_threadid_np(nil, &id)
        // Every static the hook reads is made here: a lazy global's first use allocates, which inside the hook recurses.
        _ = (allocateType, depth, buffer.load(ordering: .relaxed), capacity.load(ordering: .relaxed),
             traced.load(ordering: .relaxed), busy.load(ordering: .relaxed))
        count.store(0, ordering: .relaxed)
        thread.store(id, ordering: .relaxed)
        let previous = slot.pointee
        slot.pointee = { type, _, _, _, _, _ in
            guard type & MallocProbe.allocateType != 0 else { return }
            var id: UInt64 = 0
            pthread_threadid_np(nil, &id)
            if id == MallocProbe.thread.load(ordering: .relaxed) { MallocProbe.note() }
        }
        body()
        slot.pointee = previous
        thread.store(0, ordering: .relaxed)
        return count.load(ordering: .relaxed)
    }

    /// One counted allocation: count it and, while tracing with room left, copy its return addresses.
    static func note() {
        guard busy.load(ordering: .relaxed) == 0 else { return }
        _ = count.wrappingAdd(1, ordering: .relaxed)
        let index = traced.load(ordering: .relaxed)
        guard index < capacity.load(ordering: .relaxed),
              let base = UnsafeMutablePointer<UnsafeMutableRawPointer?>(bitPattern: buffer.load(ordering: .relaxed)) else { return }
        busy.store(1, ordering: .relaxed)
        let slots = base + index * depth
        let frames = Int(backtrace(slots, Int32(depth)))
        if frames < depth { slots[frames] = nil }
        traced.store(index + 1, ordering: .relaxed)
        busy.store(0, ordering: .relaxed)
    }

    /// Starts keeping up to `capacity` traces of the allocations counted from now on.
    static func beginTracing(capacity: Int) {
        let slots = UnsafeMutablePointer<UnsafeMutableRawPointer?>.allocate(capacity: capacity * depth)
        slots.initialize(repeating: nil, count: capacity * depth)
        traced.store(0, ordering: .relaxed)
        self.capacity.store(capacity, ordering: .relaxed)
        buffer.store(Int(bitPattern: slots), ordering: .relaxed)
    }

    /// Stops tracing and returns the traces kept (each its return addresses, innermost first).
    static func endTracing() -> [[UInt]] {
        let address = buffer.load(ordering: .relaxed)
        let total = capacity.load(ordering: .relaxed)
        buffer.store(0, ordering: .relaxed)
        capacity.store(0, ordering: .relaxed)
        guard let slots = UnsafeMutablePointer<UnsafeMutableRawPointer?>(bitPattern: address) else { return [] }
        let kept = traced.load(ordering: .relaxed)
        var traces: [[UInt]] = []
        traces.reserveCapacity(kept)
        for index in 0..<kept {
            var trace: [UInt] = []
            for slot in 0..<depth {
                guard let address = slots[index * depth + slot] else { break }
                trace.append(UInt(bitPattern: address))
            }
            traces.append(trace)
        }
        slots.deinitialize(count: total * depth)
        slots.deallocate()
        return traces
    }
}

/// Names the call sites of traced allocations (after the measured loop: this allocates freely). Each trace is
/// read as: the probe's frames, libmalloc's, then the allocating leaf (the first frame that is not an allocator
/// entry point such as `swift_allocObject`, `swift_slowAlloc` or `_objc_rootAllocWithZone`), then the frames up
/// to the first cmux frame (this test binary or a CmuxNext image) that is not the bench or the probe. Symbols come
/// from `dladdr` (symbol+offset and image).
private nonisolated struct AllocationSites {
    private nonisolated struct Frame {
        let address: UInt
        let base: UInt
        let path: String
        let image: String
        let symbol: String
        let offset: Int
        let isOwn: Bool
    }

    private typealias Demangle = @convention(c) (UnsafePointer<CChar>?, Int, UnsafeMutablePointer<CChar>?,
                                                 UnsafeMutablePointer<Int>?, UInt32) -> UnsafeMutablePointer<CChar>?

    /// One key kind's grouped traces, before its lines are written.
    nonisolated struct Summary {
        let name: String
        let allocations: Int
        let traced: Int
        let keys: Int
        fileprivate let byOwn: [(UInt, Int)]
        fileprivate let byPair: [(own: UInt?, leaf: UInt?, chain: [UInt], count: Int)]
    }

    private var frames: [UInt: Frame] = [:]
    private let ownBase = UInt(bitPattern: #dsohandle)
    private let demangle: Demangle? = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "swift_demangle")
        .map { unsafeBitCast($0, to: Demangle.self) }

    private mutating func frame(_ address: UInt) -> Frame {
        if let known = frames[address] { return known }
        var info = Dl_info()
        // A return address: the call is the instruction before it.
        let found = UnsafeRawPointer(bitPattern: address &- 1).map { dladdr($0, &info) != 0 } ?? false
        let path = found ? info.dli_fname.map { String(cString: $0) } ?? "?" : "?"
        let image = (path as NSString).lastPathComponent
        let mangled = found ? info.dli_sname.map { String(cString: $0) } : nil
        let symbol = mangled.map(readable) ?? String(format: "0x%lx", address)
        let offset = found && info.dli_saddr != nil ? Int(bitPattern: address) - Int(bitPattern: info.dli_saddr) : 0
        let base = found ? UInt(bitPattern: info.dli_fbase) : 0
        let isOwn = found && (base == ownBase || image.contains("CmuxNext"))
        let result = Frame(address: address, base: base, path: path, image: image, symbol: symbol, offset: offset, isOwn: isOwn)
        frames[address] = result
        return result
    }

    private func readable(_ mangled: String) -> String {
        guard let demangle, let text = mangled.withCString({ demangle($0, strlen($0), nil, nil, 0) }) else { return mangled }
        defer { free(text) }
        let full = String(cString: text)
        return full.count > 200 ? String(full.prefix(200)) + "..." : full
    }

    private static func isProbe(_ frame: Frame) -> Bool {
        frame.isOwn && (frame.symbol.contains("MallocProbe") || frame.symbol.contains("AllocationSites"))
    }

    private static func isBench(_ frame: Frame) -> Bool {
        frame.isOwn && frame.symbol.contains("KeyRouterBench")
    }

    private static func isAllocator(_ frame: Frame) -> Bool {
        switch frame.image {
        case "libsystem_malloc.dylib": true
        case "libswiftCore.dylib": frame.symbol.hasPrefix("swift_") || frame.symbol.hasPrefix("_swift_")
        case "libobjc.A.dylib": frame.symbol.contains("lloc") || frame.symbol.contains("createInstance")
        case "CoreFoundation": frame.symbol.hasPrefix("_CFRuntimeCreateInstance") || frame.symbol == "__CFSafelyReallocate"
        default: false
        }
    }

    /// Groups one key kind's traces by first cmux frame, and by (first cmux frame, leaf) with the frames between.
    mutating func summarize(_ name: String, traces: [[UInt]], allocations: Int, keys: Int) -> Summary {
        var byOwn: [UInt: Int] = [:]
        var byPair: [String: (own: UInt?, leaf: UInt?, chain: [UInt], count: Int)] = [:]
        for trace in traces {
            let resolved = trace.map { frame($0) }
            // Past the probe's frames and libmalloc's.
            let mallocEnd = resolved.lastIndex { $0.image == "libsystem_malloc.dylib" }.map { $0 + 1 }
            let start = min(mallocEnd ?? (resolved.firstIndex { !Self.isProbe($0) } ?? resolved.count), resolved.count)
            let rest = Array(resolved[start...])
            let leafIndex = rest.firstIndex { !Self.isAllocator($0) }
            let ownIndex = rest.firstIndex { $0.isOwn && !Self.isProbe($0) && !Self.isBench($0) }
            let own = ownIndex.map { rest[$0].address }
            let leaf = leafIndex.map { rest[$0].address }
            byOwn[own ?? 0, default: 0] += 1
            // Grouped by symbol, not address: one function's several call sites stay apart only in the chain.
            let key = "\(ownIndex.map { rest[$0].symbol } ?? "-")|\(leafIndex.map { rest[$0].symbol } ?? "-")"
            if var known = byPair[key] {
                known.count += 1
                byPair[key] = known
            } else {
                let from = leafIndex ?? 0
                let to = min(rest.count, max(from, ownIndex ?? from) + 3)
                byPair[key] = (own, leaf, rest[from..<to].map(\.address), 1)
            }
        }
        return Summary(name: name, allocations: allocations, traced: traces.count, keys: keys,
                       byOwn: byOwn.sorted { $0.value > $1.value }.prefix(20).map { ($0.key, $0.value) },
                       byPair: byPair.values.sorted { $0.count > $1.count }.prefix(20).map { $0 })
    }

    /// `KEY-ROUTER-ALLOC` lines for `summaries` (symbol+offset and image; source lines need the binary's
    /// debug map, which the fleet's `atos` did not read, so the frames are left for a reader to place).
    mutating func lines(_ summaries: [Summary]) -> [String] {
        func text(_ address: UInt?) -> String {
            guard let address, address != 0 else { return "(none)" }
            let frame = frame(address)
            return "\(frame.symbol)+\(frame.offset) [\(frame.image)]"
        }
        var lines: [String] = []
        for summary in summaries {
            let perKey = { (count: Int) in String(format: "%.2f", Double(count) / Double(max(1, summary.keys))) }
            lines.append("KEY-ROUTER-ALLOC \(summary.name): \(summary.allocations) allocations in \(summary.keys) keys "
                + "(\(perKey(summary.allocations))/key), \(summary.traced) traced")
            for (address, count) in summary.byOwn {
                lines.append("KEY-ROUTER-ALLOC \(summary.name) by-cmux-frame \(perKey(count))/key  \(text(address))")
            }
            for pair in summary.byPair {
                lines.append("KEY-ROUTER-ALLOC \(summary.name) by-site \(perKey(pair.count))/key  cmux: \(text(pair.own)) | leaf: \(text(pair.leaf))")
                lines.append("KEY-ROUTER-ALLOC \(summary.name)   chain: " + pair.chain.map { text($0) }.joined(separator: " < "))
            }
        }
        return lines
    }
}

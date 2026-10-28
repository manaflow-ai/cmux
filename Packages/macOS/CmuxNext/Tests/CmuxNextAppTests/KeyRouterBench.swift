import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextCompat
import CmuxNextFocus
import CmuxNextFocusUI
@testable import CmuxNextTerminal
import CmuxNextTestSupport
import Darwin
import Foundation
import Testing

/// KeyRouterBench (plan DC8): the real key dispatcher (`KeyRouter.interceptKeyDown`, the
/// `key-dispatch` perf-hot path) in a cmux window of a 60-workspace registry whose focused pane is a terminal,
/// one of 30 panes. It drives synthetic key-downs (a plain key, Cmd-T, Cmd-D, a when-clause binding and Ctrl-C)
/// and prints one `KEY-ROUTER-BENCH {json}` line with
/// `plain_p99_us, chord_p99_us, plain_allocs, chord_allocs, tis_calls, key_equiv_views`.
///
/// Chrome's model: input latency is a distribution read from lab benchmarks (tools/perf/benchmarks) and the
/// EventLatency histograms (cc/metrics/compositor_frame_reporter.cc), never a pass/fail timer in a unit run.
/// So this file asserts no time: the timing loop runs only with `CMUX_BENCH=1` (in Release:
/// `CMUX_BENCH=1 swift test -c release --filter KeyRouterBench`), and the agent reads the numbers. The allocation count on the calling thread (libmalloc's `malloc_logger` hook, as
/// KeyFrameSignpostAllocationTests) is the only check a plain unit run makes. It counts the router alone: the dispatch
/// context around it (`InputDispatchContext`) is `CmuxApplication.sendEvent`'s and opens outside the count. With
/// CMUX_PERF_RESULT_DIR each key kind's timed samples and counts are result-v1 (lab story swift-key-router).
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
            registry.bindEffect(candidate.id) { _ in .done }
            stubbed.append(candidate.id)
        }
        let target = try #require(stubbed.first)
        let whenKey = try #require(chords.first { $0.name == "when_clause" })
        KeyBindingLoader(registry).load(KeyBindingLayers(user: [
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

        let timing = ProcessInfo.processInfo.environment["CMUX_BENCH"] == "1"
        // The plain key measures the normal-mode path: no owner holds typing keys.
        try #require(harness.router.modes.isNormal, "modes \(harness.router.modes.active) are on: the plain key skips the normal-mode path")
        let plainRow = try Self.measure(Self.plain, in: harness, timing: timing)
        var chordRows: [(Key, Row)] = []
        for key in Self.chords { chordRows.append((key, try Self.measure(key, in: harness, timing: timing))) }
        let ctrlC = try #require(Self.chords.last)
        let keyEquivalentViews = try Self.keyEquivalentViews(ctrlC, in: harness)
        let tisCalls = try Self.tisReads(ctrlC, in: harness)

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
            "tis_calls": Self.perKey(tisCalls, keys: Self.allocationKeys),
            "key_equiv_views": Self.perKey(keyEquivalentViews, keys: Self.allocationKeys),
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
        if let results = try PerfResultWriter() {
            for (key, row) in [(Self.plain, plainRow)] + chordRows {
                if !row.nanos.isEmpty {
                    try results.record("swift.key_router.\(key.name).dispatch", unit: .us, samples: row.nanos.map { Double($0) / 1_000 })
                }
                try results.record("swift.key_router.\(key.name).allocs", unit: .count,
                                   samples: [Double(row.allocations) / Double(Self.allocationKeys)])
            }
            try results.record("swift.key_router.tis_calls", unit: .count, samples: [Double(tisCalls) / Double(Self.allocationKeys)])
            try results.record("swift.key_router.key_equiv_views", unit: .count,
                               samples: [Double(keyEquivalentViews) / Double(Self.allocationKeys)])
        }

        let fields = ["plain_p99_us", "chord_p99_us", "plain_allocs", "chord_allocs", "tis_calls", "key_equiv_views"]
        let decoded = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        for field in fields { #expect(decoded[field] != nil, "the report has no \(field)") }
        #expect(plainRow.allocations == 0, "a plain key in a terminal made \(plainRow.allocations) allocations in \(Self.allocationKeys) keys")
        // p04-input-055 makes the chord path allocation-free and turns this into a plain expectation.
        withKnownIssue("the chord path still allocates before p04-input-055", isIntermittent: true) {
            #expect(chordAllocations == 0, "the chords made \(chordAllocations) allocations in \(Self.allocationKeys * chordRows.count) keys")
        }
    }

    /// The chord step every Cmd or Ctrl key-down takes before the router resolves it
    /// (`ChordTracker.step`, then `KeyBindingTable.step`) allocates nothing: a first key that runs,
    /// one that arms a chord, the Cmd-J leader, an armed chord's next key and an unbound key.
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
        let cases: [(String, [Shortcut], ShortcutReadings)] = [
            ("cmd_t", [], ShortcutReadings(Shortcut("t", modifiers: [.command]))),
            ("cmd_k", [], ShortcutReadings(cmdK)),
            ("leader", [], ShortcutReadings(LeaderLayer.prefix)),
            ("cmd_k x", [cmdK], ShortcutReadings(x)),
            ("when_clause", [], ShortcutReadings(Shortcut("b", modifiers: [.command, .control]))),
            ("unbound", [], ShortcutReadings(Shortcut("}", modifiers: [.shift, .command]), Shortcut("]", modifiers: [.shift, .command]))),
        ]
        let isRunnable: (ActionID) -> Bool = { _ in true }
        for (name, keys, readings) in cases {
            let warm = table.step(after: keys, readings: readings, in: context, isRunnable: isRunnable)
            var step = warm
            let allocations = MallocProbe.allocations {
                for _ in 0..<Self.allocationKeys { step = table.step(after: keys, readings: readings, in: context, isRunnable: isRunnable) }
            }
            #expect(step == warm)
            #expect(allocations == 0, "\(name): the chord step made \(allocations ?? -1) allocations in \(Self.allocationKeys) keys")
        }
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

    /// The Text Input Sources reads `key` costs on the terminal's key path (`TerminalSurfaceView.keyDown`:
    /// `mayChangeSource`, then the source before and after `interpretKeyEvents` only when it may), under a
    /// keyboard layout with the system switch keys read, after the router passed it on.
    private static func tisReads(_ key: Key, in harness: Harness) throws -> Int {
        let system = InputSourceReads()
        let switchKeys = InputSourceSwitchKeys(symbolicHotKeys: nil, fnUsageType: nil)
        let sources = TerminalInputSources(reader: system.reader, readSwitchKeys: { switchKeys })
        sources.selectedSourceChanged()
        sources.switchKeys = switchKeys
        system.reads = 0
        for _ in 0..<allocationKeys {
            try autoreleasepool {
                let event = try harness.event(key)
                guard !harness.dispatch(event) else { return }
                guard sources.mayChangeSource(keyCode: event.keyCode, flags: event.modifierFlags) else { return }
                _ = sources.sourceChanged(since: sources.currentSourceID())
            }
        }
        return system.reads
    }

    /// A Text Input Sources reader that counts its reads; the selected source is a keyboard layout.
    private nonisolated final class InputSourceReads {
        var reads = 0

        var reader: TerminalInputSourceReader {
            TerminalInputSourceReader(
                current: { [unowned self] in
                    reads += 1
                    return TerminalInputSource(id: "com.apple.keylayout.ABC", isKeyboardLayout: true)
                },
                asciiKeyMap: { .empty })
        }
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
/// stack logging uses), as InputEventTapTests does.
private nonisolated struct MallocProbe {
    typealias Logger = @convention(c) (UInt32, UInt, UInt, UInt, UInt, UInt32) -> Void

    /// `MALLOC_LOG_TYPE_ALLOCATE` (libmalloc stack_logging.h).
    static let allocateType: UInt32 = 2
    static let count = Atomic<Int>(0)
    static let thread = Atomic<UInt64>(0)

    /// The allocations `body` makes on this thread, or nil when the hook is missing.
    static func allocations(_ body: () -> Void) -> Int? {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "malloc_logger") else { return nil }
        let slot = symbol.assumingMemoryBound(to: Logger?.self)
        var id: UInt64 = 0
        pthread_threadid_np(nil, &id)
        count.store(0, ordering: .relaxed)
        thread.store(id, ordering: .relaxed)
        let previous = slot.pointee
        slot.pointee = { type, _, _, _, _, _ in
            guard type & MallocProbe.allocateType != 0 else { return }
            var id: UInt64 = 0
            pthread_threadid_np(nil, &id)
            if id == MallocProbe.thread.load(ordering: .relaxed) { _ = MallocProbe.count.wrappingAdd(1, ordering: .relaxed) }
        }
        body()
        slot.pointee = previous
        thread.store(0, ordering: .relaxed)
        return count.load(ordering: .relaxed)
    }
}

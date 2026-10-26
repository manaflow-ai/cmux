import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextFocus
import Darwin
import Foundation
import Testing

/// p04-input-056: the key router's cost per key-down (`interceptKeyDown`, perf-hot `key-dispatch`), in a window of a
/// 60-workspace registry whose focused pane is a terminal: a plain printable key, Cmd-T, Cmd-D, a when-clause binding
/// (Cmd-[ is Focus History Back `when: notWebPage`) and Ctrl-C. Run on the fleet in Release:
/// `CMUX_BENCH=1 swift test -c release --filter KeyRouterBench`. It prints one `KEY-ROUTER-BENCH {json}` line with
/// `plain_p99_us`, `chord_p99_us`, `plain_allocs`, `chord_allocs`, `tis_calls`, `key_equiv_views` and each case's
/// p50/p95/p99/max. It asserts no time (Chrome's input benches report EventLatency distributions; they gate nothing).
/// Chord actions are bound to no-op effects, so the numbers are the routing (Facts, context, resolve, decide, the
/// registry run), never the split or new tab the key would make.
@MainActor @Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["CMUX_BENCH"] == "1"))
struct KeyRouterBench {
    private static let workspaceCount = 60
    private static let paneProbeCount = 30
    private static let plainIterations = 5_000
    private static let chordIterations = 2_000
    private static let allocationSamples = 64
    private static let warmup = 50

    private struct Harness {
        let services: AppServices
        let shell: NSWindow
        var router: KeyRouter { services.keyRouter }
        func close() { for controller in services.windows.controllers { controller.window?.close() } }
    }

    private struct KeyCase {
        let name: String
        let characters: String
        let ignoringModifiers: String
        let keyCode: UInt16
        let modifiers: NSEvent.ModifierFlags
    }

    private static let plain = KeyCase(name: "plain_a", characters: "a", ignoringModifiers: "a", keyCode: 0, modifiers: [])
    private static let chords = [
        KeyCase(name: "cmd_t", characters: "t", ignoringModifiers: "t", keyCode: 17, modifiers: [.command]),
        KeyCase(name: "cmd_d", characters: "d", ignoringModifiers: "d", keyCode: 2, modifiers: [.command]),
        KeyCase(name: "cmd_bracket_when", characters: "[", ignoringModifiers: "[", keyCode: 33, modifiers: [.command]),
        KeyCase(name: "ctrl_c_terminal", characters: "\u{3}", ignoringModifiers: "c", keyCode: 8, modifiers: [.control]),
    ]

    static let requiredFields: Set<String> = [
        "plain_p99_us", "chord_p99_us", "plain_allocs", "chord_allocs", "tis_calls", "key_equiv_views",
    ]

    private static func harness() throws -> Harness {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        services.windows.ordersWindowsIn = false
        let workspaces = (0..<workspaceCount).map { "bench-workspace-\($0)" }
        let controller = try #require(services.windows.openWindow(workspaces: workspaces))
        let shell = try #require(controller.window)
        controller.focus.send(.topology(FocusTopology(workspace: workspaces[0], panes: [
            .init(id: "bench-pane", tabs: [.init(id: "bench-tab", kind: .terminal)], selected: "bench-tab"),
        ])))
        controller.focus.send(.focusPane("bench-pane", source: .keyboard))
        try #require(controller.focus.state.resolved == .terminal(pane: "bench-pane", tab: "bench-tab"))
        return Harness(services: services, shell: shell)
    }

    private static var timestamp: TimeInterval = 90_000

    /// A new key-down each call: the router never decides the same event twice (`DecidedKeyEvents`). Made inside
    /// the caller's autorelease pool, so it dies after its dispatch as a real key-down does.
    private static func event(_ key: KeyCase, in harness: Harness) throws -> NSEvent {
        timestamp += 0.001
        return try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: key.modifiers,
                                             timestamp: timestamp, windowNumber: harness.shell.windowNumber,
                                             context: nil, characters: key.characters,
                                             charactersIgnoringModifiers: key.ignoringModifiers, isARepeat: false,
                                             keyCode: key.keyCode))
    }

    /// The router's decision for `event`, dispatched as `CmuxApplication.sendEvent` does.
    @discardableResult
    private static func dispatch(_ event: NSEvent, in harness: Harness) -> Bool {
        harness.router.dispatchingSynthetic(event) { harness.router.interceptKeyDown(event, in: harness.shell) }
    }

    private struct Measurement {
        var samples: [UInt64]
        var allocations: Int
        var action: String?

        func percentileMicros(_ fraction: Double) -> Double {
            let sorted = samples.sorted()
            guard !sorted.isEmpty else { return 0 }
            let index = min(sorted.count - 1, max(0, Int((Double(sorted.count) * fraction).rounded(.up)) - 1))
            return Double(sorted[index]) / 1_000
        }

        var row: [String: Any] {
            ["p50_us": percentileMicros(0.50), "p95_us": percentileMicros(0.95), "p99_us": percentileMicros(0.99),
             "max_us": percentileMicros(1), "allocs": allocations, "action": (action as Any?) ?? NSNull(),
             "n": samples.count]
        }
    }

    /// Times `iterations` key-downs of `key` one by one, then counts the most allocations one key-down made on this
    /// thread over `allocationSamples` more (each under its own probe, so the timing never pays for the logger).
    private static func measure(_ key: KeyCase, iterations: Int, in harness: Harness) throws -> Measurement {
        for _ in 0..<warmup {
            _ = try autoreleasepool { dispatch(try event(key, in: harness), in: harness) }
        }
        var samples: [UInt64] = []
        samples.reserveCapacity(iterations)
        var action: String?
        for _ in 0..<iterations {
            try autoreleasepool {
                let keyDown = try event(key, in: harness)
                let start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
                dispatch(keyDown, in: harness)
                samples.append(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - start)
                action = harness.router.lastInterception?.action.rawValue
            }
        }
        var allocations = 0
        for _ in 0..<allocationSamples {
            try autoreleasepool {
                let keyDown = try event(key, in: harness)
                let count = try #require(ThreadAllocationProbe.allocations { dispatch(keyDown, in: harness) },
                                         "malloc_logger is missing: allocations cannot be counted")
                allocations = max(allocations, count)
            }
        }
        return Measurement(samples: samples, allocations: allocations, action: action)
    }

    /// AppKit's key-equivalent walk for an undecided chord: how many of `paneProbeCount` pane-sized views
    /// `performKeyEquivalent` visits (a 30-pane window; 086 makes it the focused view only).
    private static func keyEquivalentViews(_ event: NSEvent, in harness: Harness) throws -> Int {
        let content = try #require(harness.shell.contentView)
        let container = NSView(frame: content.bounds)
        let probes = (0..<paneProbeCount).map { index in
            KeyEquivalentProbe(frame: NSRect(x: CGFloat(index % 6) * 40, y: CGFloat(index / 6) * 40, width: 40, height: 40))
        }
        for probe in probes { container.addSubview(probe) }
        content.addSubview(container)
        defer { container.removeFromSuperview() }
        harness.router.dispatchingSynthetic(event) {
            if !harness.router.interceptKeyDown(event, in: harness.shell) { _ = harness.shell.performKeyEquivalent(with: event) }
        }
        return probes.reduce(0) { $0 + $1.visits }
    }

    /// TISCopyCurrentKeyboardInputSource calls `TerminalSurfaceView.keyDown` makes for `flags`: two around
    /// `interpretKeyEvents` when `GhosttyInput.mayChangeInputSource` holds (the same rule; 096 removes the calls).
    private static func terminalTISCalls(_ flags: NSEvent.ModifierFlags) -> Int {
        flags.isDisjoint(with: [.control, .option, .command, .function]) ? 0 : 2
    }

    @Test func keyRouterCostPerKeyDown() throws {
        // An Objective-C allocation: Release cannot optimize it away as it can a Swift array.
        let control = ThreadAllocationProbe.allocations { withExtendedLifetime(NSMutableData(length: 256)) {} }
        try #require((control ?? 0) > 0, "malloc_logger saw no allocation on this thread: the probe cannot measure here")

        let harness = try Self.harness()
        defer { harness.close() }
        // Each chord's action runs a no-op effect: the bench times routing, not the split or the new tab.
        var noOps: Set<String> = []
        for key in Self.chords {
            guard let resolved = harness.services.registry.resolveShortcut(for: try Self.event(key, in: harness)) else { continue }
            harness.services.registry.bindEffect(resolved.id) { _ in .done }
            noOps.insert(resolved.id.rawValue)
        }

        let plain = try Self.measure(Self.plain, iterations: Self.plainIterations, in: harness)
        var rows: [String: Any] = [Self.plain.name: plain.row]
        var chordSamples: [UInt64] = []
        var chordAllocations = 0
        for key in Self.chords {
            let measured = try Self.measure(key, iterations: Self.chordIterations, in: harness)
            var row = measured.row
            // False: the key ran an action the bench did not stub, so its time includes that action's work.
            row["no_op"] = measured.action.map { noOps.contains($0) } ?? true
            rows[key.name] = row
            chordSamples += measured.samples
            chordAllocations = max(chordAllocations, measured.allocations)
        }
        let chords = Measurement(samples: chordSamples, allocations: chordAllocations, action: nil)
        let ctrlC = try #require(Self.chords.last)
        let keyEquivalentEvent = try Self.event(ctrlC, in: harness)

        let report: [String: Any] = [
            "plain_p99_us": plain.percentileMicros(0.99),
            "chord_p99_us": chords.percentileMicros(0.99),
            "plain_allocs": plain.allocations,
            "chord_allocs": chords.allocations,
            "tis_calls": Self.terminalTISCalls(ctrlC.modifiers),
            "key_equiv_views": try Self.keyEquivalentViews(keyEquivalentEvent, in: harness),
            "workspaces": Self.workspaceCount,
            "cases": rows,
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        print("KEY-ROUTER-BENCH \(String(decoding: data, as: UTF8.self))")
        let decoded = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Self.requiredFields.isSubset(of: Set(decoded.keys)), "missing \(Self.requiredFields.subtracting(decoded.keys))")
    }
}

/// Counts `performKeyEquivalent` visits: one stands for one pane's view in AppKit's depth-first walk.
private final class KeyEquivalentProbe: NSView {
    private(set) var visits = 0

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        visits += 1
        return super.performKeyEquivalent(with: event)
    }
}

/// This thread's counter while `ThreadAllocationProbe.allocations` runs (nil on every other thread).
private nonisolated let allocationCounterKey: pthread_key_t? = {
    var key = pthread_key_t()
    return pthread_key_create(&key, nil) == 0 ? key : nil
}()

/// Counts the allocations the calling thread makes, through libmalloc's `malloc_logger` hook (the one malloc stack
/// logging uses). Other threads see no counter in their thread-specific slot, so they count nothing.
private nonisolated struct ThreadAllocationProbe {
    typealias Logger = @convention(c) (UInt32, UInt, UInt, UInt, UInt, UInt32) -> Void

    /// `MALLOC_LOG_TYPE_ALLOCATE` (libmalloc stack_logging.h).
    static let allocateType: UInt32 = 2

    /// The allocations `body` makes on this thread, or nil when the hook or the thread key is missing.
    static func allocations(_ body: () -> Void) -> Int? {
        guard let key = allocationCounterKey,
              let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "malloc_logger") else { return nil }
        let slot = symbol.assumingMemoryBound(to: Logger?.self)
        let counter = UnsafeMutablePointer<Int>.allocate(capacity: 1)
        counter.initialize(to: 0)
        defer { counter.deallocate() }
        pthread_setspecific(key, counter)
        let previous = slot.pointee
        slot.pointee = { type, _, _, _, _, _ in
            guard type & ThreadAllocationProbe.allocateType != 0, let key = allocationCounterKey,
                  let counter = pthread_getspecific(key) else { return }
            counter.assumingMemoryBound(to: Int.self).pointee += 1
        }
        body()
        slot.pointee = previous
        pthread_setspecific(key, nil)
        return counter.pointee
    }
}

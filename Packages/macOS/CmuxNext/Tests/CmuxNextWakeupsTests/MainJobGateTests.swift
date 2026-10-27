import AppKit
import CmuxNextCompat
import Darwin
import Testing
@testable import CmuxNextWakeups
import CmuxNextWakeupsTestSupport

/// The MainJobGate on the main run loop and in the Swift runtime (p04-input-076): held jobs go
/// after the frame's commit with an input check between them, a menu's tracking loop releases them
/// at its entry and suspends holding until its exit, the real hook holds a `Task {}` made on main
/// while input is pending and its uninstall releases it, and the switch off installs no hook.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct MainJobGateTests {
    static let refresh: UInt64 = 16_666_667
    static let tracking = CFRunLoopMode(RunLoop.Mode.eventTracking.rawValue as CFString)

    /// After each commit, one held job goes while no input is pending, none while input is.
    @Test func drainForwardsOneJobPerCommitWithInputCheck() {
        let rig = GateRig()
        let input = InputFlag()
        let loop = MainJobGateRunLoop(gate: rig.gate, kinds: { [.key] }, inputPending: { input.pending }, refreshNanos: { Self.refresh })
        defer { loop.invalidate() }
        rig.state.publish(.key)
        rig.gate.enqueue(MainJobGateClassTests.job(1))
        rig.gate.enqueue(MainJobGateClassTests.job(2))
        input.pending = true
        #expect(!loop.drainAfterCommit())
        #expect(rig.forwarded.jobs.isEmpty)
        input.pending = false
        #expect(loop.drainAfterCommit())
        #expect(rig.forwarded.jobs == [MainJobGateClassTests.job(1).job])
        #expect(loop.drainAfterCommit())
        #expect(!loop.drainAfterCommit())
        #expect(rig.forwarded.jobs == [MainJobGateClassTests.job(1).job, MainJobGateClassTests.job(2).job])
    }

    /// The input's commit (Core Animation's beforeWaiting observer, order 2000000) runs before the
    /// first held job is forwarded.
    @Test func commitHappensBeforeFirstHeldJob() {
        let order = EventOrder()
        let state = InputPendingState()
        let gate = MainJobGate(state: state, forward: { _ in order.note("job") }, wakeMain: {})
        // A deadline far away: only the drain after the commit may forward the job.
        let loop = MainJobGateRunLoop(gate: gate, kinds: { [] }, inputPending: { false }, refreshNanos: { 10_000_000_000 })
        let commit = MainRunLoopObserver(activities: .beforeWaiting, order: 2_000_000) { _ in order.note("commit") }
        defer { loop.invalidate(); commit.invalidate() }
        state.publish(.key)
        gate.enqueue(MainJobGateClassTests.job(1))
        #expect(order.events.isEmpty)
        _ = CFRunLoopRunInMode(.defaultMode, 0.05, false)
        #expect(Array(order.events.prefix(2)) == ["commit", "job"])
    }

    /// The deadline is also checked before a pass's timers (a pass that never waits has no commit).
    @Test func deadlineCheckedBeforeTimers() {
        let clock = ManualClock()
        let rig = GateRig(clock: clock)
        let loop = MainJobGateRunLoop(gate: rig.gate, kinds: { [.key] }, inputPending: { true }, refreshNanos: { Self.refresh })
        defer { loop.invalidate() }
        rig.state.publish(.key)
        rig.gate.enqueue(MainJobGateClassTests.job(1))
        loop.turn(.beforeTimers)
        #expect(rig.forwarded.jobs.isEmpty)
        clock.advance(by: .milliseconds(17))
        loop.turn(.beforeTimers)
        #expect(rig.forwarded.jobs == [MainJobGateClassTests.job(1).job])
        #expect(rig.gate.counters.releasedBy["deadline"] == 1)
    }

    /// A menu's tracking loop releases the FIFO at its entry; inside it nothing is held; after its
    /// exit holding starts again.
    @Test func trackingLoopReleasesAtEntry() {
        let rig = GateRig()
        let loop = MainJobGateRunLoop(gate: rig.gate, kinds: { [.key] }, inputPending: { true }, refreshNanos: { Self.refresh })
        defer { loop.invalidate() }
        rig.state.publish(.key)
        rig.gate.enqueue(MainJobGateClassTests.job(1))
        rig.gate.enqueue(MainJobGateClassTests.job(2))
        let inside = InsideLoop()
        let gate = rig.gate, state = rig.state, forwarded = rig.forwarded
        // A block in the mode: the run loop enters a mode only when it has something to run.
        // main-hop-allow: the test's work inside the tracking loop it runs
        CFRunLoopPerformBlock(CFRunLoopGetMain(), Self.tracking.rawValue) {
            gate.enqueue(MainJobGateClassTests.job(3))
            inside.record(forwarded: forwarded.jobs, bits: state.bits)
        }
        _ = CFRunLoopRunInMode(Self.tracking, 0, true)
        #expect(inside.forwarded == [1, 2, 3].map { MainJobGateClassTests.job($0).job })
        #expect(inside.bits.contains(.nestedLoop))
        #expect(!rig.state.bits.contains(.nestedLoop))
        #expect(rig.gate.counters.releasedBy["nested_loop"] == 2)
        #expect(rig.gate.counters.exemptByRule["nested_loop"] == 1)
        rig.gate.enqueue(MainJobGateClassTests.job(4))
        #expect(rig.gate.heldCount == 1, "holding starts again after the loop exits")
    }

    /// The runtime hook: a `Task {}` made on main while a key is pending is held, the same made
    /// inside a dispatch passes, and the uninstall releases the held one and removes the hook.
    @Test func runtimeHookHoldsMainTaskUntilRelease() async throws {
        let hook = try MainJobGateHook()
        let before = Self.runtimeHook()
        let state = InputPendingState()
        let gate = MainJobGate(state: state)
        let ran = ForwardedJobs()
        try hook.install(gate)
        #expect(Self.runtimeHook() != before)
        state.publish(.key)
        // main-hop-allow: the test's held main-actor task
        let held = Task { @MainActor in ran.append(1) }
        let heldNow = gate.heldCount
        let outer = state.beginDispatch()
        // main-hop-allow: the test's main-actor task made in a dispatch
        let passed = Task { @MainActor in ran.append(2) }
        state.endDispatch(restoring: outer)
        state.publish([])
        hook.uninstall()
        #expect(heldNow >= 1, "the task made outside input waits")
        #expect(gate.counters.exemptByRule["in_dispatch"].map { $0 >= 1 } == true)
        #expect(Self.runtimeHook() == before)
        await held.value
        await passed.value
        #expect(Set(ran.jobs) == [1, 2])
        #expect(gate.heldCount == 0)
    }

    /// The switch off (feature on, `debug.mainJobGate` false) installs no hook; nil (settings not
    /// loaded) changes nothing.
    @Test func switchOffInstallsNoHook() {
        let before = Self.runtimeHook()
        let jobGate = MainJobGateSwitch(pending: SessionInputPending(events: QuietSessionEvents()))
        jobGate.setEnabled(false)
        #expect(!jobGate.isEnabled)
        #expect(Self.runtimeHook() == before)
    }

    /// The runtime's hook variable now, as an address (0: none).
    static func runtimeHook() -> UInt {
        // SAFETY: the variable MainJobGateHook.init resolves: one pointer, read whole.
        guard let address = unsafe dlsym(dlopen(nil, RTLD_NOW), MainJobGateHook.symbol) else { return 0 }
        // SAFETY: as above.
        return unsafe address.assumingMemoryBound(to: UInt.self).pointee
    }
}

/// Whether input is pending, as a test sets it.
@MainActor
final class InputFlag {
    var pending = false
}

/// The order of named events.
final class EventOrder: Sendable {
    // concurrency-allow: the events, noted by the gate's forward and by an observer (lock carve-out: one array append or copy).
    private let noted = Mutex<[String]>([])

    func note(_ event: String) { noted.withLock { $0.append(event) } }
    var events: [String] { noted.withLock { $0 } }
}

/// What a block inside a nested loop saw.
final class InsideLoop: Sendable {
    // concurrency-allow: written once by the block inside the loop, read by the test after it (lock carve-out).
    private let seen = Mutex<(forwarded: [UInt], bits: InputPendingState.Bits)>(([], []))

    func record(forwarded: [UInt], bits: InputPendingState.Bits) { seen.withLock { $0 = (forwarded, bits) } }
    var forwarded: [UInt] { seen.withLock { $0.forwarded } }
    var bits: InputPendingState.Bits { seen.withLock { $0.bits } }
}

/// A session where nothing is pending (the app is inactive).
@MainActor
final class QuietSessionEvents: SessionInputEvents {
    func secondsSinceLastInput() -> TimeInterval { .infinity }
    func secondsSinceLastEvent(_ type: CGEventType) -> TimeInterval { .infinity }
    var isAppActive: Bool { false }
    var refreshInterval: TimeInterval { 1.0 / 60 }
    var pointerIsOverAppWindow: Bool { false }
    func observeDispatch(_ dispatched: @escaping @MainActor @Sendable (SessionInputPending.Dispatched) -> Void) {}
}

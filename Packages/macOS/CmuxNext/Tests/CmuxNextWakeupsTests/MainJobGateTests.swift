import AppKit
import CmuxNextCompat
import Darwin
import Observation
import Testing
@testable import CmuxNextWakeups
import CmuxNextWakeupsTestSupport

/// The MainJobGate on the main run loop and in the Swift runtime: held jobs go
/// after the frame's commit with an input check between them, the one-refresh deadline releases
/// them only after a commit stage and has its own wake, a menu's tracking loop releases them at its
/// entry and suspends holding until its exit, the end of a dispatch drops the input it dispatched,
/// the real hook holds a `Task {}` made on main while input is pending and its uninstall releases
/// it, and the switch installs the hook only while the setting is on.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct MainJobGateTests {
    static let refresh: UInt64 = 16_666_667
    static let tracking = CFRunLoopMode(RunLoop.Mode.eventTracking.rawValue as CFString)

    /// After each commit, one held job goes while no input is pending, none while input is.
    @Test func drainForwardsOneJobPerCommitWithInputCheck() {
        let rig = GateRig(clock: ManualClock())
        let input = InputFlag()
        let wakes = DeadlineWakes()
        let loop = MainJobGateRunLoop(gate: rig.gate, kinds: { [.key] }, inputPending: { input.pending },
                                      refreshNanos: { Self.refresh }, wakeAtDeadline: { wakes.arm($0) })
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
        #expect(rig.gate.counters.releasedBy["drained"] == 2)
    }

    /// The input's commit (Core Animation's beforeWaiting observer, order 2000000) runs before the
    /// first held job is forwarded.
    @Test func commitHappensBeforeFirstHeldJob() {
        let order = EventOrder()
        let state = InputPendingState()
        let gate = MainJobGate(state: state, forward: { _ in order.note("job") }, wakeMain: {})
        // A deadline far away: only the drain after the commit may forward the job.
        let loop = MainJobGateRunLoop(gate: gate, kinds: { [] }, inputPending: { false }, refreshNanos: { 10_000_000_000 },
                                      wakeAtDeadline: { _ in {} })
        let commit = MainRunLoopObserver(activities: [.beforeWaiting, .exit], order: 2_000_000) { _ in order.note("commit") }
        defer { loop.invalidate(); commit.invalidate() }
        state.publish(.key)
        gate.enqueue(MainJobGateClassTests.job(1))
        #expect(order.events.isEmpty)
        Self.runTurn(timeout: 0.05)
        #expect(Array(order.events.prefix(2)) == ["commit", "job"])
    }

    /// Past the deadline, with the input not committed yet, the pass's commit still comes before
    /// the released jobs: no stage before the commit (after the wait, before the timers) releases.
    @Test func deadlineReleasesOnlyAfterTheCommit() {
        let clock = ManualClock()
        let order = EventOrder()
        let state = InputPendingState()
        let gate = MainJobGate(state: state, forward: { _ in order.note("job") }, uptimeNanos: { GateRig.nanos(clock.now.offset) },
                               wakeMain: {})
        let loop = MainJobGateRunLoop(gate: gate, kinds: { [.key] }, inputPending: { true }, refreshNanos: { Self.refresh },
                                      wakeAtDeadline: { _ in {} })
        let commit = MainRunLoopObserver(activities: [.beforeWaiting, .exit], order: 2_000_000) { _ in order.note("commit") }
        defer { loop.invalidate(); commit.invalidate() }
        state.publish(.key)
        gate.enqueue(MainJobGateClassTests.job(1))
        gate.enqueue(MainJobGateClassTests.job(2))
        clock.advance(by: .milliseconds(17))
        loop.turnStarted()
        #expect(order.events.isEmpty, "the turn's start releases nothing")
        // A pass that polls: no wait, so its commit stage is the run loop's exit.
        Self.runTurn(timeout: 0)
        #expect(Array(order.events.prefix(3)) == ["commit", "job", "job"])
        #expect(gate.counters.releasedBy["deadline"] == 2)
        #expect(gate.counters.deferredOverOneFrame == 2)
    }

    /// Input that stays pending and is never dispatched: the drain arms one wake for the hold's
    /// deadline, and the commit stage of the pass that wake starts releases the FIFO.
    @Test func deadlineHasItsOwnWake() {
        let clock = ManualClock()
        let rig = GateRig(clock: clock)
        let wakes = DeadlineWakes()
        let loop = MainJobGateRunLoop(gate: rig.gate, kinds: { [.key] }, inputPending: { true }, refreshNanos: { Self.refresh },
                                      wakeAtDeadline: { wakes.arm($0) })
        defer { loop.invalidate() }
        rig.state.publish(.key)
        rig.gate.enqueue(MainJobGateClassTests.job(1))
        clock.advance(by: .milliseconds(5))
        #expect(!loop.drainAfterCommit())
        #expect(!loop.drainAfterCommit())
        #expect(wakes.delays == [.nanoseconds(Int64(Self.refresh)) - .milliseconds(5)], "one wake per hold, at its deadline")
        rig.gate.enqueue(MainJobGateClassTests.job(2))
        clock.advance(by: .milliseconds(12))
        #expect(loop.drainAfterCommit(), "the woken pass's commit stage")
        #expect(rig.forwarded.jobs == [MainJobGateClassTests.job(1).job, MainJobGateClassTests.job(2).job])
        #expect(wakes.cancelled == 1)
        rig.gate.enqueue(MainJobGateClassTests.job(3))
        #expect(!loop.drainAfterCommit())
        #expect(wakes.delays.count == 2, "a new hold arms its own wake")
    }

    /// The app's deadline wake is a precise entry on the main thread's deadline queue; its cancel drops it.
    @Test func deadlineWakeIsAQueueEntry() {
        let work = MainWorkScheduler.testing { _ in nil }
        let before = work.wakeUps.count
        let cancel = MainJobGateRunLoop.wake(on: work.wakeUps)(.milliseconds(16))
        #expect(work.wakeUps.count == before + 1)
        cancel()
        #expect(work.wakeUps.count == before)
    }

    /// A menu's tracking loop releases the FIFO at its entry; inside it nothing is held; after its
    /// exit holding starts again.
    @Test func trackingLoopReleasesAtEntry() {
        let rig = GateRig()
        let loop = MainJobGateRunLoop(gate: rig.gate, kinds: { [.key] }, inputPending: { true }, refreshNanos: { Self.refresh },
                                      wakeAtDeadline: { _ in {} })
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

    /// At the end of a key's dispatch the kinds still pending are published again: a job made later
    /// in the same pass passes, unless more input is on its way.
    @Test func endOfDispatchDropsTheDispatchedInput() {
        let events = OneKeySessionEvents()
        let rig = GateRig(clock: ManualClock())
        let work = MainWorkScheduler.testing { _ in nil }
        let jobGate = MainJobGateSwitch(pending: SessionInputPending(events: events), gate: rig.gate, wakeUps: work.wakeUps)
        rig.state.publish(.key)
        let outer = jobGate.beginDispatch()
        events.dispatchKey()
        jobGate.endDispatch(restoring: outer)
        #expect(!rig.state.bits.contains(.key))
        rig.gate.enqueue(MainJobGateClassTests.job(1))
        #expect(rig.forwarded.jobs == [MainJobGateClassTests.job(1).job], "the key was dispatched: nothing is pending")

        events.keyPending = true
        rig.state.publish(.key)
        let again = jobGate.beginDispatch()
        jobGate.endDispatch(restoring: again)
        rig.gate.enqueue(MainJobGateClassTests.job(2))
        #expect(rig.gate.heldCount == 1, "a key still on its way holds the job")
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

    /// The switch follows `debug.mainJobGate`: nil (settings not loaded) installs nothing, true
    /// installs the hook, false uninstalls it and releases what was held.
    @Test func switchFollowsTheSetting() {
        let before = Self.runtimeHook()
        let clock = ManualClock()
        let recorded = ForwardedJobs()
        // A key on its way the whole test and a clock that never moves: only the switch releases.
        let pending = SessionInputPending(events: OneKeySessionEvents())
        let gate = MainJobGate(state: InputPendingState(), forward: { entry in
            // A real main-actor job held meanwhile goes to the runtime; the test's entry is recorded.
            if entry.original == 0 { recorded.append(entry.job) } else { MainJobGate.runtimeForward(entry) }
        }, uptimeNanos: { GateRig.nanos(clock.now.offset) }, wakeMain: { CFRunLoopWakeUp(CFRunLoopGetMain()) })
        let work = MainWorkScheduler.testing { _ in nil }
        let jobGate = MainJobGateSwitch(pending: pending, gate: gate, wakeUps: work.wakeUps)
        let setting = GateSetting()
        defer { jobGate.setEnabled(false) }
        jobGate.follow(on: work) { setting.enabled }
        #expect(!jobGate.isEnabled)
        #expect(Self.runtimeHook() == before, "settings not loaded: no hook")

        setting.enabled = true
        #expect(Self.spin { jobGate.isEnabled })
        #expect(Self.runtimeHook() != before, "on: the hook is installed")
        gate.state.publish(.key)
        gate.enqueue(MainJobGateClassTests.job(1))
        #expect(gate.heldCount >= 1)

        setting.enabled = false
        #expect(Self.spin { !jobGate.isEnabled })
        #expect(Self.runtimeHook() == before, "off: the hook is gone")
        #expect(recorded.jobs == [MainJobGateClassTests.job(1).job], "off releases what was held")
        #expect(gate.counters.releasedBy["uninstalled"].map { $0 >= 1 } == true)
        #expect(gate.heldCount == 0)
    }

    /// The runtime's hook variable now, as an address (0: none).
    static func runtimeHook() -> UInt {
        // SAFETY: the variable MainJobGateHook.init resolves: one pointer, read whole.
        guard let address = unsafe dlsym(dlopen(nil, RTLD_NOW), MainJobGateHook.symbol) else { return 0 }
        // SAFETY: as above.
        return unsafe address.assumingMemoryBound(to: UInt.self).pointee
    }

    /// One run of the main run loop in the default mode. A far-future timer keeps the mode from
    /// being empty (inside a main-queue callout the main queue does not), so the loop runs its observers.
    static func runTurn(timeout: CFTimeInterval) {
        let timer = CFRunLoopTimerCreateWithHandler(nil, CFAbsoluteTimeGetCurrent() + 3_600, 0, 0, 0) { _ in }
        CFRunLoopAddTimer(CFRunLoopGetMain(), timer, .defaultMode)
        _ = CFRunLoopRunInMode(.defaultMode, timeout, false)
        CFRunLoopTimerInvalidate(timer)
    }

    /// Runs the main run loop until `done` holds, for at most 5 s; returns `done()`.
    static func spin(until done: () -> Bool) -> Bool {
        let end = Date(timeIntervalSinceNow: 5)
        while !done(), Date() < end {
            _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        }
        return done()
    }
}

/// Whether input is pending, as a test sets it.
@MainActor
final class InputFlag {
    var pending = false
}

/// The `debug.mainJobGate` value a test sets (nil: settings not loaded).
@MainActor @Observable
final class GateSetting {
    var enabled: Bool?
}

/// The deadline wakes a run loop armed and how many it cancelled.
@MainActor
final class DeadlineWakes {
    private(set) var delays: [Duration] = []
    private(set) var cancelled = 0

    func arm(_ delay: Duration) -> @MainActor () -> Void {
        delays.append(delay)
        return { [weak self] in self?.cancelled += 1 }
    }
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

/// A session with one key on its way until ``dispatchKey()``; the app is active. The key on its way
/// is always 1 ms old, so it never goes stale however long the test runs.
@MainActor
final class OneKeySessionEvents: SessionInputEvents {
    /// A key is on its way (set it again for a key generated after the dispatched one).
    var keyPending = true
    private var dispatched: (@MainActor @Sendable (SessionInputPending.Dispatched) -> Void)?

    func secondsSinceLastInput() -> TimeInterval { keyPending ? 0.001 : .infinity }
    func secondsSinceLastEvent(_ type: CGEventType) -> TimeInterval { keyPending && type == .keyDown ? 0.001 : .infinity }
    var isAppActive: Bool { true }
    var refreshInterval: TimeInterval { 1.0 / 60 }
    var pointerIsOverAppWindow: Bool { false }
    func observeDispatch(_ dispatched: @escaping @MainActor @Sendable (SessionInputPending.Dispatched) -> Void) {
        self.dispatched = dispatched
    }

    /// AppKit dispatched the key, generated a second ago: a key on its way later is newer.
    func dispatchKey() {
        keyPending = false
        dispatched?(SessionInputPending.Dispatched(timestamp: ProcessInfo.processInfo.systemUptime - 1, kind: .keyOrClick))
    }
}

import CmuxNextCompat
@testable import CmuxNextTrace
import Testing

/// `begin`/`end` scopes (a C hook's frame begin and end, p09-observability-120) on a clock that moves only when
/// the test moves it: their slot's kernel timer lease, which keeps a renderer that draws now and then from
/// waking the parked monitor, and an unregister from another thread racing a begin.
@Suite("Hang watch frame scopes") struct HangWatchFrameScopeTests {
    /// A focused terminal's cursor blinking for 30 s (a 2 ms frame every 600 ms) wakes the parked monitor never,
    /// and its timer never fires: each frame only moves the timer later.
    @Test func blinkFramesNeverWakeTheParkedMonitor() {
        let rig = LeasedRig()
        let renderer = rig.watch.registerThread(.renderer, name: "test.renderer")
        for _ in 0..<50 {
            rig.watch.begin(renderer, deadline: .milliseconds(500))
            rig.now.advance(.milliseconds(2))
            rig.watch.end(renderer)
            rig.now.advance(.milliseconds(598))
            #expect(rig.timers.fire(of: renderer).map { $0 > rig.now.nanos } == true, "the slot's timer fired")
        }
        #expect(rig.wakes.count == 0)
        #expect(rig.watch.wakeRequests == 0)
        #expect(rig.watch.leaseRenewals <= 50, "at most one timer move per frame")
    }

    /// Frames at 120 Hz for 5 s move the timer about once per 500 ms budget, not once per frame.
    @Test func denseFramesMoveTheTimerOncePerBudget() {
        let rig = LeasedRig()
        let renderer = rig.watch.registerThread(.renderer, name: "test.renderer")
        for _ in 0..<600 {
            rig.watch.begin(renderer, deadline: .milliseconds(500))
            rig.now.advance(.milliseconds(1))
            rig.watch.end(renderer)
            rig.now.advance(.microseconds(7_333))
        }
        #expect(rig.wakes.count == 0)
        #expect(rig.watch.leaseRenewals <= 11, "\(rig.watch.leaseRenewals) timer moves in 5 s")
    }

    /// A frame that never ends is scanned when its timer fires, one budget past its deadline: a jank naming the
    /// thread's subject, then the hang tier on the monitor's own plan, on time.
    @Test func aStuckFrameIsScannedWhenItsTimerFires() throws {
        let rig = LeasedRig()
        let renderer = rig.watch.registerThread(.renderer, name: "test.renderer", subject: 0x51)
        let opened = rig.now.nanos
        rig.watch.begin(renderer, deadline: .milliseconds(500))
        let fire = try #require(rig.timers.fire(of: renderer))
        #expect(fire == opened + 1_000_000_000, "one budget past the deadline")
        #expect(rig.wakes.count == 0)
        let planned = try #require(rig.watch.nextScanNanos)
        #expect(planned <= fire, "the timer's wake is a scan")

        rig.now.advance(.seconds(1))
        let jank = rig.watch.scan(nowNanos: rig.now.nanos)
        #expect(jank.overdue.map(\.tier) == [.jank])
        #expect(jank.overdue.first?.subject == 0x51)
        let hangDue = opened + 2_500_000_000
        #expect(jank.nextScanNanos == hangDue, "the hang tier on the monitor's own plan")

        rig.now.advance(.milliseconds(1_500))
        let hang = rig.watch.scan(nowNanos: rig.now.nanos)
        #expect(hang.overdue.map(\.tier) == [.hang])
        #expect(hang.overdue.first?.name == "test.renderer")
        rig.watch.end(renderer)
        #expect(hang.overdue.first.map(rig.watch.isStillOpen) == false)
    }

    /// The renderer stops drawing (its terminal lost focus): the timer fires once, the scan finds nothing open and
    /// the monitor parks with no period of its own.
    @Test func aTimerAfterTheLastFrameParksTheMonitor() throws {
        let rig = LeasedRig()
        let renderer = rig.watch.registerThread(.renderer, name: "test.renderer")
        rig.watch.begin(renderer, deadline: .milliseconds(500))
        rig.now.advance(.milliseconds(2))
        rig.watch.end(renderer)
        let fire = try #require(rig.timers.fire(of: renderer))
        rig.now.advance(.nanoseconds(Int64(fire - rig.now.nanos)))
        let result = rig.watch.scan(nowNanos: rig.now.nanos)
        #expect(result.overdue.isEmpty)
        #expect(result.nextScanNanos == nil, "parked: no rescan one period later")
    }

    /// With no slot timers, a begin wakes the parked monitor as a `watch` scope does.
    @Test func withNoSlotTimersABeginWakesTheMonitor() {
        let rig = LeasedRig(timers: false)
        let renderer = rig.watch.registerThread(.renderer, name: "test.renderer")
        rig.watch.begin(renderer, deadline: .milliseconds(500))
        #expect(rig.wakes.count == 1)
        #expect(rig.watch.leaseRenewals == 0)
    }

    /// A surface's destroy on another thread frees the renderer's slot after the renderer's begin checked it and
    /// before it stored the deadline: the freed slot holds no scope, so nothing is reported for the destroyed
    /// surface and no dead thread is sampled.
    @Test func aBeginRacingItsSlotsUnregisterLeavesNoScope() {
        let rig = LeasedRig()
        let renderer = rig.watch.registerThread(.renderer, name: "test.renderer")
        rig.onNextClockRead { watch in watch.unregister(renderer) }
        rig.watch.begin(renderer, deadline: .milliseconds(500))
        rig.now.advance(.seconds(5))
        #expect(rig.watch.scan(nowNanos: rig.now.nanos).overdue.isEmpty)
    }

    /// The same race with the freed slot claimed again before the old renderer's store: the new registration's
    /// slot keeps its own word, and its own frames are watched.
    @Test func aBeginRacingItsSlotsReuseLeavesTheNewOwnersWord() throws {
        let rig = LeasedRig()
        let old = rig.watch.registerThread(.renderer, name: "test.old")
        let next = Reclaimed()
        rig.onNextClockRead { watch in
            watch.unregister(old)
            next.packed.store(watch.registerThread(.renderer, name: "test.next").packed, ordering: .releasing)
        }
        rig.watch.begin(old, deadline: .milliseconds(500))
        let reused = HangWatch.Registration(packed: next.packed.load(ordering: .acquiring))
        #expect(reused.slot == old.slot)
        rig.now.advance(.seconds(5))
        #expect(rig.watch.scan(nowNanos: rig.now.nanos).overdue.isEmpty, "the old renderer's frame is not the new slot's scope")

        rig.watch.begin(reused, deadline: .milliseconds(500))
        rig.now.advance(.seconds(5))
        #expect(rig.watch.scan(nowNanos: rig.now.nanos).overdue.map(\.name) == ["test.next"])
    }
}

/// A monitored slot table on a manual clock, with the monitor's wakes and each slot's kernel timer recorded.
private struct LeasedRig {
    let now: FrameClock
    let wakes: FrameWakes
    let timers: SlotTimers
    let watch: HangWatch

    init(timers withTimers: Bool = true) {
        let (now, timers, wakes) = (FrameClock(), SlotTimers(), FrameWakes())
        (self.now, self.timers, self.wakes) = (now, timers, wakes)
        watch = HangWatch(clock: TraceClock(reader: .init(uptimeNanos: { now.read() }, continuousNow: { ContinuousClock.now })))
        let lease: (@Sendable (Int, UInt64) -> Void)? = { index, after in timers.arm(index, fireNanos: now.nanos + after) }
        watch.attachMonitor(wake: { wakes.add() }, leaseTimer: withTimers ? lease : nil)
        now.attach(watch)
    }

    /// Runs `body` inside the slot table's next clock read: the read `begin` makes after it checked its slot and
    /// before it stores the deadline.
    func onNextClockRead(_ body: @escaping @Sendable (HangWatch) -> Void) {
        now.onNextRead(body)
    }
}

/// A `CLOCK_UPTIME_RAW` reading that moves only when the test moves it, and can run one action inside a read.
private final class FrameClock: Sendable {
    let start: UInt64 = 1_000_000_000_000
    private let offset = Atomic<UInt64>(0)
    private let table = Atomic<UInt>(0)
    private let action = Mutex<(@Sendable (HangWatch) -> Void)?>(nil)

    var nanos: UInt64 { start + offset.load(ordering: .acquiring) }

    func advance(_ duration: Duration) {
        offset.add(HangWatch.nanos(duration), ordering: .acquiringAndReleasing)
    }

    /// The slot table, unretained (the rig holds it).
    func attach(_ watch: HangWatch) {
        table.store(UInt(bitPattern: Unmanaged.passUnretained(watch).toOpaque()), ordering: .releasing)
    }

    func onNextRead(_ body: @escaping @Sendable (HangWatch) -> Void) {
        action.withLock { $0 = body }
    }

    func read() -> UInt64 {
        if let body = action.withLock({ pending in defer { pending = nil }; return pending }),
           let pointer = UnsafeRawPointer(bitPattern: table.load(ordering: .acquiring)) {
            body(Unmanaged<HangWatch>.fromOpaque(pointer).takeUnretainedValue())
        }
        return nanos
    }
}

/// The registration a clock-read action made.
private final class Reclaimed: Sendable {
    let packed = Atomic<UInt64>(0)
}

/// The monitor wakes the slot table asked for.
private final class FrameWakes: Sendable {
    private let value = Atomic<Int>(0)
    var count: Int { value.load(ordering: .acquiring) }
    func add() { value.add(1, ordering: .acquiringAndReleasing) }
}

/// Each slot's kernel timer: when it fires, as the last `leaseTimer` call set it.
private final class SlotTimers: Sendable {
    private let fires = Mutex<[Int: UInt64]>([:])

    func arm(_ index: Int, fireNanos: UInt64) {
        fires.withLock { $0[index] = fireNanos }
    }

    func fire(of registration: HangWatch.Registration) -> UInt64? {
        fires.withLock { $0[Int(registration.slot)] }
    }
}

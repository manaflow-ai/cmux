@testable import CmuxNextWakeups
import Testing

/// DelayPolicy and WakeLeeway: Chromium's 8 ms leeway and 36 ms precise limit
/// below 1 s, whole uptime seconds with min(10%, 1 s) leeway above, 32 ms in Energy Saver.
@Suite("WakeLeeway")
struct WakeLeewayTests {
    private static let ms: UInt64 = 1_000_000
    private static let second: UInt64 = 1_000_000_000

    struct Row: Sendable, CustomTestStringConvertible {
        let delay: Duration
        let policy: DelayPolicy
        let alignment: Duration
        let leeway: Duration
        let grid: Duration
        let effective: DelayPolicy
        var testDescription: String { "\(delay) \(policy) alignment \(alignment)" }
    }

    static let table: [Row] = [
        Row(delay: .milliseconds(20), policy: .precise, alignment: WakeLeeway.defaultAlignment,
            leeway: .zero, grid: .zero, effective: .precise),
        Row(delay: .milliseconds(35), policy: .precise, alignment: WakeLeeway.defaultAlignment,
            leeway: .zero, grid: .zero, effective: .precise),
        Row(delay: .milliseconds(36), policy: .precise, alignment: WakeLeeway.defaultAlignment,
            leeway: .milliseconds(8), grid: .milliseconds(8), effective: .flexibleNoSooner),
        Row(delay: .milliseconds(100), policy: .precise, alignment: WakeLeeway.defaultAlignment,
            leeway: .milliseconds(8), grid: .milliseconds(8), effective: .flexibleNoSooner),
        Row(delay: .milliseconds(450), policy: .flexibleNoSooner, alignment: WakeLeeway.defaultAlignment,
            leeway: .milliseconds(8), grid: .milliseconds(8), effective: .flexibleNoSooner),
        Row(delay: .milliseconds(450), policy: .flexiblePreferEarly, alignment: WakeLeeway.defaultAlignment,
            leeway: .milliseconds(8), grid: .milliseconds(8), effective: .flexiblePreferEarly),
        Row(delay: .seconds(1), policy: .flexibleNoSooner, alignment: WakeLeeway.defaultAlignment,
            leeway: .milliseconds(100), grid: .seconds(1), effective: .flexibleNoSooner),
        Row(delay: .seconds(5), policy: .flexibleNoSooner, alignment: WakeLeeway.defaultAlignment,
            leeway: .milliseconds(500), grid: .seconds(1), effective: .flexibleNoSooner),
        Row(delay: .seconds(5), policy: .precise, alignment: WakeLeeway.defaultAlignment,
            leeway: .milliseconds(500), grid: .seconds(1), effective: .flexibleNoSooner),
        Row(delay: .seconds(60), policy: .flexibleNoSooner, alignment: WakeLeeway.defaultAlignment,
            leeway: .seconds(1), grid: .seconds(1), effective: .flexibleNoSooner),
        Row(delay: .milliseconds(100), policy: .flexibleNoSooner, alignment: WakeLeeway.saverAlignment,
            leeway: .milliseconds(32), grid: .milliseconds(32), effective: .flexibleNoSooner),
        Row(delay: .milliseconds(20), policy: .precise, alignment: WakeLeeway.saverAlignment,
            leeway: .zero, grid: .zero, effective: .precise),
        Row(delay: .seconds(5), policy: .flexibleNoSooner, alignment: WakeLeeway.saverAlignment,
            leeway: .milliseconds(500), grid: .seconds(1), effective: .flexibleNoSooner),
        Row(delay: .zero, policy: .flexibleNoSooner, alignment: WakeLeeway.defaultAlignment,
            leeway: .zero, grid: .zero, effective: .precise),
        Row(delay: .milliseconds(100), policy: .flexibleNoSooner, alignment: .zero,
            leeway: .milliseconds(8), grid: .milliseconds(8), effective: .flexibleNoSooner),
    ]

    @Test("The policy table gives the leeway, the grid and the effective policy", arguments: WakeLeewayTests.table)
    func policyTable(_ row: Row) {
        let window = WakeLeeway.window(delay: row.delay, policy: row.policy, alignment: row.alignment)
        #expect(window.leeway == row.leeway)
        #expect(window.tolerance == row.leeway)
        #expect(window.grid == row.grid)
        #expect(window.policy == row.effective)
        #expect(window.delay == row.delay)
    }

    @Test("The default policy is flexibleNoSooner and the default alignment 8 ms")
    func defaults() {
        let window = WakeLeeway.window(delay: .milliseconds(450))
        #expect(window.policy == .flexibleNoSooner)
        #expect(window.leeway == .milliseconds(8))
        #expect(window.grid == .milliseconds(8))
    }

    @Test("A precise wake below 36 ms fires exactly at its deadline")
    func preciseIsExact() {
        let window = WakeLeeway.window(delay: .milliseconds(20), policy: .precise)
        let deadline = 7 * Self.second + 3 * Self.ms + 17
        #expect(window.earliest(deadline: deadline) == deadline)
        #expect(window.latest(deadline: deadline) == deadline)
        #expect(window.fireTime(deadline: deadline) == deadline)
        #expect(window.sleepDelay == .milliseconds(20))
    }

    @Test("A sub-second flexible wake fires on the next 8 ms boundary, never before the deadline")
    func subSecondAligns() {
        let window = WakeLeeway.window(delay: .milliseconds(450))
        let deadline = 10 * Self.second + 450 * Self.ms + 1
        let fire = window.fireTime(deadline: deadline)
        #expect(fire % (8 * Self.ms) == 0)
        #expect(fire >= deadline)
        #expect(fire <= window.latest(deadline: deadline))
        #expect(fire == 10 * Self.second + 456 * Self.ms)
    }

    @Test("A deadline on a boundary fires on it")
    func boundaryFiresOnIt() {
        let window = WakeLeeway.window(delay: .milliseconds(100))
        let deadline = 3 * Self.second + 104 * Self.ms
        #expect(window.fireTime(deadline: deadline) == deadline)
    }

    @Test("Energy Saver aligns sub-second wakes to 32 ms")
    func saverAlignsTo32() {
        let window = WakeLeeway.window(delay: .milliseconds(100), alignment: WakeLeeway.saverAlignment)
        let deadline = 2 * Self.second + 101 * Self.ms
        let fire = window.fireTime(deadline: deadline)
        #expect(fire == 2 * Self.second + 112 * Self.ms)
        #expect(fire % (32 * Self.ms) == 0)
    }

    @Test("A 5 s wake gets 500 ms and fires on a whole uptime second when one is in its window")
    func fiveSecondsWholeSecond() {
        let window = WakeLeeway.window(delay: .seconds(5))
        #expect(window.leeway == .milliseconds(500))
        let deadline = 12 * Self.second + 700 * Self.ms
        #expect(window.fireTime(deadline: deadline) == 13 * Self.second)
    }

    @Test("A 5 s wake whose window holds no whole second fires at its latest, never after")
    func fiveSecondsClampsToLatest() {
        let window = WakeLeeway.window(delay: .seconds(5))
        let deadline = 12 * Self.second + 300 * Self.ms
        #expect(window.fireTime(deadline: deadline) == 12 * Self.second + 800 * Self.ms)
        #expect(window.fireTime(deadline: deadline) == window.latest(deadline: deadline))
    }

    @Test("A 60 s wake gets 1 s of leeway and always lands on a whole uptime second")
    func sixtySecondsAlwaysWholeSecond() {
        let window = WakeLeeway.window(delay: .seconds(60))
        #expect(window.leeway == .seconds(1))
        for offset: UInt64 in [0, 1, 300 * Self.ms, 999 * Self.ms + 999_999] {
            let deadline = 100 * Self.second + offset
            let fire = window.fireTime(deadline: deadline)
            #expect(fire % Self.second == 0)
            #expect(fire >= deadline && fire <= window.latest(deadline: deadline))
        }
    }

    @Test("flexiblePreferEarly fires within the leeway before the deadline, never after it")
    func preferEarly() {
        let window = WakeLeeway.window(delay: .milliseconds(450), policy: .flexiblePreferEarly)
        let deadline = 10 * Self.second + 455 * Self.ms
        #expect(window.earliest(deadline: deadline) == 10 * Self.second + 447 * Self.ms)
        #expect(window.latest(deadline: deadline) == deadline)
        #expect(window.fireTime(deadline: deadline) == 10 * Self.second + 448 * Self.ms)
        #expect(window.sleepDelay == .milliseconds(442))
        #expect(window.tolerance == .milliseconds(8))
    }

    @Test("Window bounds saturate at the ends of the uptime range")
    func saturates() {
        let noSooner = WakeLeeway.window(delay: .seconds(60))
        #expect(noSooner.latest(deadline: .max - 1) == .max)
        #expect(noSooner.fireTime(deadline: .max - 1) == .max)
        let early = WakeLeeway.window(delay: .seconds(60), policy: .flexiblePreferEarly)
        #expect(early.earliest(deadline: 5) == 0)
        #expect(early.fireTime(deadline: 5) == 0)
    }

    @Test("An own-tolerance window keeps its tolerance and grid; the heap's Energy Saver alignment never moves it")
    func ownToleranceIgnoresAlignment() {
        let window = WakeLeeway.own(tolerance: .milliseconds(8), delay: .milliseconds(100))
        #expect(window.policy == .flexibleNoSooner)
        #expect(window.leeway == .milliseconds(8) && window.grid == .milliseconds(8))
        #expect(!window.followsAlignment)
        #expect(WakeLeeway.window(delay: .milliseconds(100)).followsAlignment)
        #expect(!WakeLeeway.window(delay: .seconds(5)).followsAlignment)
        let deadline = 2 * Self.second + 101 * Self.ms
        var heap = MainWakeUpHeap<Int>()
        heap.alignment = WakeLeeway.saverAlignment.nanosecondCount
        heap.insert(.init(id: 1, deadline: deadline, window: window, owner: "own", payload: 1))
        #expect(heap.wakeUp()?.date == 2 * Self.second + 104 * Self.ms, "its own 8 ms grid, not the saver's 32 ms")
        #expect(heap.wakeUp()?.latest == 2 * Self.second + 109 * Self.ms)
    }

    @Test("An own-tolerance window with no tolerance or no delay is exact")
    func ownToleranceZeroIsPrecise() {
        for window in [WakeLeeway.own(tolerance: .zero, delay: .milliseconds(100)), .own(tolerance: .milliseconds(8), delay: .zero)] {
            #expect(window.policy == .precise)
            #expect(window.fireTime(deadline: 5 * Self.ms + 3) == 5 * Self.ms + 3)
        }
    }

    @Test("DelayPolicy.effective is Chromium's MaybeOverrideDelayPolicy")
    func effectivePolicy() {
        #expect(DelayPolicy.precise.effective(for: .milliseconds(35)) == .precise)
        #expect(DelayPolicy.precise.effective(for: DelayPolicy.maxPreciseDelay) == .flexibleNoSooner)
        #expect(DelayPolicy.flexiblePreferEarly.effective(for: .seconds(10)) == .flexiblePreferEarly)
        #expect(DelayPolicy.flexibleNoSooner.effective(for: .zero) == .precise)
        #expect(DelayPolicy.flexibleNoSooner.effective(for: .milliseconds(-5)) == .precise)
    }

    @Test("Duration converts to whole nanoseconds; negative is zero")
    func nanoseconds() {
        #expect(Duration.milliseconds(8).nanosecondCount == 8 * Self.ms)
        #expect(Duration.seconds(3).nanosecondCount == 3 * Self.second)
        #expect(Duration.nanoseconds(1_500).nanosecondCount == 1_500)
        #expect(Duration.milliseconds(-1).nanosecondCount == 0)
    }
}

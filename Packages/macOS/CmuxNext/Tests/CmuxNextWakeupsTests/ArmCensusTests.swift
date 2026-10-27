#if DEBUG || CMUX_BENCH_HOOKS
@testable import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Foundation
import Testing

/// The launch's arm census (p08-startup-085, queue Q13): a timer, a main deadline and a folder watch armed while the
/// census records leave one record each, with their owner, the line that made them, how often they were armed before
/// their first fire, and that first fire, also when it comes after the census closed. Nothing is recorded before the
/// census starts or after it closes, and arms past the capacity are counted. Every clock is the test's.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct ArmCensusTests {
    nonisolated private static let ms: UInt64 = 1_000_000

    /// A ledger on a fake uptime and a main wake-up queue on a fake timer that records into it.
    @MainActor
    private struct Rig {
        let uptime = FakeUptime(10 * ArmCensusTests.ms)
        let ledger: WakeupLedger
        let wakeTimer = FakeWakeUpTimer()
        let queue: MainWakeUpQueue

        init() {
            let uptime = uptime, wakeTimer = wakeTimer
            ledger = WakeupLedger(uptime: { uptime.now })
            queue = MainWakeUpQueue(energy: EnergyPolicySource(), ledger: ledger, uptime: { uptime.now }) { _ in wakeTimer }
        }

        var census: ArmCensus { ledger.armCensus }

        func timer(_ owner: String, line: UInt = #line) -> DemandTimer {
            DemandTimer(owner: owner, ledger: ledger, wakeUps: queue, line: line)
        }

        func fire() {
            if let date = wakeTimer.armedDate { uptime.now = date }
            wakeTimer.fired()
            queue.fire()
        }
    }

    @Test func aTimerArmedDuringTheLaunchRecordsItsOwnerSiteArmsAndFirstFire() throws {
        let rig = Rig()
        rig.census.start(processStartNanos: 2 * Self.ms)
        let timer = rig.timer("test.launch-timer", line: 40)
        rig.uptime.now = 20 * Self.ms
        timer.scheduleOnMain(after: .milliseconds(100)) {}
        rig.uptime.now = 30 * Self.ms
        timer.scheduleOnMain(after: .milliseconds(100)) {}
        timer.scheduleOnMain(after: .milliseconds(100)) {}
        rig.fire()

        let snapshot = rig.census.snapshot()
        #expect(snapshot.started && !snapshot.closed && snapshot.dropped == 0)
        let arm = try #require(snapshot.arms.only)
        #expect(arm.kind == .timer)
        #expect(arm.owner == "test.launch-timer")
        #expect(arm.site.description.hasSuffix("ArmCensusTests.swift:40"), "the line that made it, not DemandTimer's")
        #expect(arm.armedNanos == 20 * Self.ms, "its first arm")
        #expect(arm.count == 3, "three arms before the first fire")
        let fire = try #require(arm.firstFireNanos)
        #expect(fire >= 130 * Self.ms, "no sooner than the last reset's deadline")

        // After its first fire it records nothing more: a later arm is no new record and no count.
        timer.scheduleOnMain(after: .milliseconds(100)) {}
        rig.fire()
        #expect(rig.census.snapshot().arms.count == 1)
        #expect(rig.census.snapshot().arms.first?.count == 3)
        #expect(rig.census.snapshot().arms.first?.firstFireNanos == fire)
    }

    @Test func nothingIsRecordedBeforeTheStartOrAfterTheClose() {
        let rig = Rig()
        let early = rig.timer("test.before-start")
        early.scheduleOnMain(after: .milliseconds(5)) {}
        #expect(rig.census.snapshot().arms.isEmpty, "a launch without CMUX_NEXT_ARM_CENSUS records nothing")
        #expect(!rig.census.isRecording)

        rig.census.start(processStartNanos: 0)
        let launch = rig.timer("test.launch")
        launch.scheduleOnMain(after: .seconds(3)) {}
        rig.census.close()
        launch.scheduleOnMain(after: .seconds(3)) {}
        let late = rig.timer("test.after-close")
        late.scheduleOnMain(after: .milliseconds(5)) {}
        for _ in 0..<3 { rig.fire() }

        let snapshot = rig.census.snapshot()
        #expect(snapshot.closed)
        #expect(snapshot.arms.map(\.owner) == ["test.launch"])
        #expect(snapshot.arms.first?.count == 1, "an arm after the close is not counted")
        #expect(snapshot.arms.first?.firstFireNanos != nil, "a first fire after the close is still recorded")
    }

    @Test func aCancelledTimerKeepsItsRecordWithNoFire() {
        let rig = Rig()
        rig.census.start(processStartNanos: 0)
        let timer = rig.timer("test.cancelled")
        timer.scheduleOnMain(after: .milliseconds(50)) {}
        timer.cancel()
        rig.fire()
        #expect(rig.census.snapshot().arms.map(\.owner) == ["test.cancelled"])
        #expect(rig.census.snapshot().arms.first?.firstFireNanos == nil)
    }

    @Test func aTimerOnTheClockRecordsItsFirstFire() async throws {
        let uptime = FakeUptime(0)
        let ledger = WakeupLedger(uptime: { uptime.now })
        let clock = ManualClock()
        ledger.armCensus.start(processStartNanos: 0)
        let timer = DemandTimer(owner: "test.sleeping", clock: clock, ledger: ledger)
        let fired = AsyncStream<Void>.makeStream()
        timer.schedule(after: .milliseconds(40)) { fired.continuation.yield() }
        try await clock.waitForSleeper()
        uptime.now = 40 * Self.ms
        clock.advance(by: .milliseconds(50))
        var iterator = fired.stream.makeAsyncIterator()
        _ = await iterator.next()
        let arm = try #require(ledger.armCensus.snapshot().arms.only)
        #expect(arm.owner == "test.sleeping")
        #expect(arm.firstFireNanos == 40 * Self.ms)
    }

    @Test func armsPastTheCapacityAreCounted() {
        let census = ArmCensus(uptimeNanos: { 0 })
        census.start(processStartNanos: 0)
        let site = ArmCensus.Site(file: #fileID, line: #line)
        for _ in 0..<ArmCensus.capacity { _ = census.armed(.timer, owner: "test.many", site: site) }
        #expect(census.armed(.timer, owner: "test.one-too-many", site: site) == nil)
        let snapshot = census.snapshot()
        #expect(snapshot.arms.count == ArmCensus.capacity)
        #expect(snapshot.dropped == 1)
    }

    @Test func theReplyIsInMillisecondsSinceProcessStart() throws {
        let uptime = FakeUptime(0)
        let census = ArmCensus(uptimeNanos: { uptime.now })
        census.start(processStartNanos: 1_000 * Self.ms)
        let site = ArmCensus.Site(file: "CmuxNextLaunch/Example.swift", line: 12)
        uptime.now = 1_250 * Self.ms + 340_000
        let fired = try #require(census.armed(.watcher, owner: "FolderChanges", site: site))
        _ = census.armed(.mainDeadline, owner: "test.never", site: site)
        uptime.now = 4_000 * Self.ms
        census.fired(fired)

        let reply = census.snapshot().foundationObject
        let summary = try #require(reply["arm_census"] as? [String: Any])
        #expect(summary["armed"] as? Bool == true)
        #expect(summary["dropped"] as? Int == 0)
        let arms = try #require(reply["arms"] as? [[String: Any]])
        #expect(arms.count == 2)
        #expect(arms[0]["kind"] as? String == "watcher")
        #expect(arms[0]["site"] as? String == "CmuxNextLaunch/Example.swift:12")
        #expect(arms[0]["armed_ms"] as? Double == 250.3)
        #expect(arms[0]["first_fire_ms"] as? Double == 3_000)
        #expect(arms[1]["kind"] as? String == "main_deadline")
        #expect(arms[1]["first_fire_ms"] is NSNull)
    }

    @Test func aFolderWatchRecordsItsArmAndFirstChange() async throws {
        let folder = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("arm-census-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let ledger = WakeupLedger()
        ledger.armCensus.start(processStartNanos: 0)
        var changes = FolderChanges(folders: [folder], ledger: ledger).events().makeAsyncIterator()
        // The loop task arms the watch when it starts; the census shows it then (bounded, 5 s).
        for _ in 0..<500 {
            if !ledger.armCensus.snapshot().arms.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let armed = try #require(ledger.armCensus.snapshot().arms.only)
        #expect(armed.kind == .watcher)
        #expect(armed.owner == "FolderChanges")
        #expect(armed.site.description.contains("ArmCensusTests.swift"))
        #expect(armed.firstFireNanos == nil)

        try Data([0]).write(to: folder.appendingPathComponent("new.png"))
        #expect(await changes.next() != nil)
        #expect(ledger.armCensus.snapshot().arms.only?.firstFireNanos != nil)
    }
}

private extension Array {
    /// The one element, or nil when there are none or several.
    var only: Element? { count == 1 ? first : nil }
}
#endif

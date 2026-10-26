import CmuxNextCompat
@testable import CmuxNextControl
import CmuxNextSettings
import CmuxNextWakeups
import Foundation
import Testing

/// `debug.energy` (p14-energy-007, 008): the exact top-level keys, the idle histogram, the wake queue's wakes, the ledger's top
/// owners, the process counters Chrome's way (interrupt wakeups, not summed with package-idle ones),
/// and sampling off the main thread.
@Suite(.timeLimit(.minutes(1)))
struct EnergyReportTests {
    private final class Threads: Sendable {
        private let onMain = Mutex<[Bool]>([])
        func note() { onMain.withLock { $0.append(Thread.isMainThread) } }
        var seen: [Bool] { onMain.withLock { $0 } }
    }

    private static let state = EnergyReport.State(
        policy: EnergyPolicy(saverReason: .battery, onBattery: true),
        inputs: .init(lowPowerMode: false, onBattery: true, hasBattery: true, batteryPercent: 15, thermal: .nominal,
                      setting: .auto, sessionOverride: false),
        wakeQueue: .init(entries: 3),
        cef: .init(saver: .unsupported, earlyPasses: nil)
    )

    private static func report(ledger: WakeupLedger = WakeupLedger(),
                               processes: @escaping @Sendable () -> [ProcessEnergy] = { [] }) async -> JSONValue {
        await EnergyReport(state: { Self.state }, ledger: ledger, processes: processes).report()
    }

    @Test func topLevelKeysAreExactlyTheSixAndIdle() async throws {
        let report = await Self.report()
        let object = try #require(report.objectValue)
        #expect(Set(object.keys) == ["policy", "inputs", "wake_queue", "ledger_top", "processes", "cef", "idle"])
        #expect(object["policy"]?["is_saver"]?.boolValue == true)
        #expect(object["policy"]?["reason"]?.stringValue == "battery")
        #expect(object["policy"]?["wake_alignment_ms"]?.doubleValue == 32)
        #expect(object["policy"]?["web_frame_rate"]?.intValue == 30)
        #expect(object["policy"]?["poll_stretch"]?.intValue == 4)
        #expect(object["inputs"]?["has_battery"]?.boolValue == true)
        #expect(object["inputs"]?["battery_percent"]?.intValue == 15)
        #expect(object["inputs"]?["thermal"]?.stringValue == "nominal")
        #expect(object["inputs"]?["setting"]?.stringValue == "auto")
        #expect(object["inputs"]?["suspended"]?.boolValue == false)
        #expect(object["inputs"]?["screens_asleep"]?.boolValue == false)
        #expect(object["inputs"]?["reason"]?.stringValue == "battery")
        #expect(object["wake_queue"]?["entries"]?.intValue == 3)
        #expect(object["wake_queue"]?["alignment_ms"]?.doubleValue == 32)
        #expect(object["cef"]?["energy_saver"]?.stringValue == "unsupported")
        #expect(object["cef"]?["early_passes"] == JSONValue.null)
    }

    @Test func saverOffReportsNullReasonsAndNoCaps() async {
        let off = EnergyReport.State(policy: .normal, inputs: Self.state.inputs, wakeQueue: .init(entries: 0),
                                     cef: Self.state.cef)
        let report = await EnergyReport(state: { off }, ledger: WakeupLedger(), processes: { [] }).report()
        #expect(report["policy"]?["reason"] == JSONValue.null)
        #expect(report["policy"]?["ambient_max_fps"] == JSONValue.null)
        #expect(report["policy"]?["wake_alignment_ms"]?.doubleValue == 8)
        #expect(report["inputs"]?["reason"] == JSONValue.null)
    }

    @Test func wakeQueueFiresComeFromTheQueuesOwnLedgerRecord() async {
        let ledger = WakeupLedger(uptime: { 100_000_000_000 })
        ledger.record(MainWakeUpQueue.ledgerOwner, reason: "fire", count: 7)
        ledger.record(MainWakeUpQueue.ledgerOwner, reason: "other", count: 9)
        ledger.record("DemandTimer", reason: "fire", count: 50)
        let report = await Self.report(ledger: ledger)
        #expect(report["wake_queue"]?["fires"]?.intValue == 7)
    }

    @Test func idleReportsTheHistogramAndItsPercentiles() async throws {
        var idle = IdleEnergyStats()
        var uptime: UInt64 = 0
        var wakeups: UInt64 = 0
        idle.noteWake(at: uptime, inputEvents: 0) { wakeups }
        uptime += IdleEnergyStats.idleAfterNanos
        idle.noteWake(at: uptime, inputEvents: 0) { wakeups }
        for _ in 0..<3 {
            uptime += IdleEnergyStats.windowNanos
            wakeups += 12
            idle.noteWake(at: uptime, inputEvents: 0) { wakeups }
        }
        var state = Self.state
        state.idle = idle
        let report = await EnergyReport(state: { [state] in state }, ledger: WakeupLedger(), processes: { [] }).report()
        let section = try #require(report["idle"])
        #expect(section["scope"]?.stringValue == "main_process")
        #expect(section["idle_after_s"]?.intValue == 60)
        #expect(section["window_s"]?.intValue == 60)
        #expect(section["samples"]?.intValue == 3)
        #expect(section["windows_with_input"]?.intValue == 0)
        #expect(section["p50"]?.doubleValue == 0.25)
        #expect(section["p99"]?.doubleValue == 0.25)
        let buckets = try #require(section["buckets"]?.arrayValue)
        #expect(buckets.map { $0["le"]?.stringValue } == ["0", "0.1", "0.25", "0.5", "1", "2", "5", "10", "50", "50+"])
        #expect(buckets.map { $0["count"]?.intValue } == [0, 0, 3, 0, 0, 0, 0, 0, 0, 0])
    }

    @Test func idleBeforeTheFirstIdleMinuteHasNullRates() async {
        let report = await Self.report()
        #expect(report["idle"]?["samples"]?.intValue == 0)
        #expect(report["idle"]?["p50"] == JSONValue.null)
        #expect(report["idle"]?["max"] == JSONValue.null)
    }

    @Test func goneServicesReportNull() async {
        let report = await EnergyReport(state: { nil }, ledger: WakeupLedger(), processes: { [] }).report()
        #expect(report == JSONValue.null)
    }

    @MainActor
    @Test func processSamplingRunsOffTheMainThread() async {
        let threads = Threads()
        let report = await Self.report {
            threads.note()
            return [ProcessEnergy(kind: "app", pid: 1, name: "cmux", energyNanojoules: 5,
                                  interruptWakeups: 10, packageIdleWakeups: 4)]
        }
        #expect(threads.seen == [false], "sampled on: \(threads.seen) (true = the main thread)")
        let process = report["processes"]?.arrayValue?.first
        #expect(process?["interrupt_wakeups"]?.intValue == 10, "interrupt wakeups are not summed with package-idle ones")
        #expect(process?["pkg_idle_wakeups"]?.intValue == 4)
        #expect(process?["energy_nj"]?.intValue == 5)
    }

    @Test func ledgerTopSumsReasonsPerOwnerAndKeepsTen() {
        // A still clock: every rate is 0, so owners rank by count.
        let ledger = WakeupLedger(uptime: { 100_000_000_000 })
        ledger.record("CEFMessagePump", reason: "delayed", count: 20)
        ledger.record("CEFMessagePump", reason: "now", count: 10)
        ledger.record("BusyWatchdog", reason: "window", count: 25)
        for index in 1...12 { ledger.record("owner\(index)", count: UInt32(index)) }
        let top = EnergyReport.LedgerOwner.top(ledger.snapshot(), count: EnergyReport.ledgerTopCount)
        #expect(top.count == 10)
        #expect(top.map(\.owner).prefix(3) == ["CEFMessagePump", "BusyWatchdog", "owner12"])
        #expect(top.first?.count == 30)
        #expect(top.first?.reasons == ["delayed", "now"])
        #expect(top.last?.owner == "owner5")
    }

    @Test func thermalStatesHaveStableNames() {
        let names = [ProcessInfo.ThermalState.nominal, .fair, .serious, .critical].map(EnergyReport.Inputs.name)
        #expect(names == ["nominal", "fair", "serious", "critical"])
    }

    @Test func samplesThisProcess() throws {
        let me = try #require(ProcessEnergy.sample(kind: "app", pid: getpid(), name: "test"))
        #expect(me.pid == getpid())
        #expect(me.kind == "app")
    }
}

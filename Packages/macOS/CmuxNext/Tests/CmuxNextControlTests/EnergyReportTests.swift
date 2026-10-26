import CmuxNextCompat
@testable import CmuxNextControl
import CmuxNextSettings
import CmuxNextWakeups
import Foundation
import Testing

/// `debug.energy` (p14-energy-007): the exact top-level keys, the wake queue's wakes, the ledger's top
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

    @Test func topLevelKeysAreExactlyTheSix() async throws {
        let report = await Self.report()
        let object = try #require(report.objectValue)
        #expect(Set(object.keys) == ["policy", "inputs", "wake_queue", "ledger_top", "processes", "cef"])
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

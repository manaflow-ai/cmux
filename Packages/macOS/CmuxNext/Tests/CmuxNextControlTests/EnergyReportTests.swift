import CmuxNextCompat
@testable import CmuxNextControl
import CmuxNextSettings
import CmuxNextWakeups
import Foundation
import Testing

/// `debug.energy`: the exact top-level keys, the idle histogram, the field names the idle bench reads, the
/// wake queue's wakes, the ledger's top owners, the process counters Chrome's way (interrupt wakeups, not
/// summed with package-idle ones) from one sample, and sampling off the main thread.
@Suite(.timeLimit(.minutes(1)))
struct EnergyReportTests {
    private final class Threads: Sendable {
        private let onMain = Mutex<[Bool]>([])
        func note() { onMain.withLock { $0.append(Thread.isMainThread) } }
        var seen: [Bool] { onMain.withLock { $0 } }
    }

    private static let inputs = EnergyReport.Inputs(
        featureEnabled: true, lowPowerMode: false, onBattery: true, hasBattery: true, batteryPercent: 15,
        thermal: .nominal, setting: .auto, sessionOverride: false
    )

    private static let state = EnergyReport.State(
        policy: EnergyPolicy(saverReason: .battery, onBattery: true),
        inputs: inputs,
        wakeQueue: .init(entries: 3, coalescedFires: 2),
        cef: .init(saver: .unsupported, earlyPasses: nil)
    )

    private static func report(state: EnergyReport.State = Self.state, ledger: WakeupLedger = WakeupLedger(),
                               processes: @escaping @Sendable () -> [EnergyReport.ProcessSample] = { [] }) async -> JSONValue {
        await EnergyReport(state: { state }, ledger: ledger, processes: processes).report()
    }

    private static func usage(pid: pid_t, interrupt: UInt64, packageIdle: UInt64, energy: UInt64) -> ProcessUsage {
        ProcessUsage(pid: pid, parent: 0, path: "/Applications/cmux NEXT.app/Contents/MacOS/cmux", cpuNanos: 0,
                     wakeups: interrupt &+ packageIdle, interruptWakeups: interrupt, packageIdleWakeups: packageIdle,
                     energyNanojoules: energy, physFootprint: 0, uptimeNanos: 0)
    }

    @Test func topLevelKeysAreExactlyTheEight() async throws {
        let report = await Self.report()
        let object = try #require(report.objectValue)
        #expect(Set(object.keys) == ["policy", "inputs", "wake_queue", "ledger_top", "processes", "cef", "idle", "tabs"])
        #expect(object["policy"]?["reason"]?.stringValue == "battery")
        #expect(object["policy"]?["wakeAlignmentMs"]?.doubleValue == 32)
        #expect(object["policy"]?["webFrameRate"]?.intValue == 30)
        #expect(object["policy"]?["pollStretch"]?.intValue == 4)
        #expect(object["policy"]?["pageSaver"]?.boolValue == true)
        #expect(object["inputs"]?["featureEnabled"]?.boolValue == true)
        #expect(object["inputs"]?["hasBattery"]?.boolValue == true)
        #expect(object["inputs"]?["batteryPercent"]?.intValue == 15)
        #expect(object["inputs"]?["thermal"]?.stringValue == "nominal")
        #expect(object["inputs"]?["setting"]?.stringValue == "auto")
        #expect(object["inputs"]?["sessionOverride"]?.boolValue == false)
        #expect(object["inputs"]?["suspended"]?.boolValue == false)
        #expect(object["inputs"]?["screensAsleep"]?.boolValue == false)
        #expect(object["wake_queue"]?["entries"]?.intValue == 3)
        #expect(object["wake_queue"]?["coalescedFires"]?.intValue == 2)
        #expect(object["wake_queue"]?["alignmentMs"]?.doubleValue == 32)
        #expect(object["cef"]?["energySaver"]?.stringValue == "unsupported")
        #expect(object["cef"]?["earlyPasses"] == JSONValue.null)
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
        let report = await Self.report(state: state)
        let section = try #require(report["idle"])
        #expect(section["scope"]?.stringValue == "mainProcess")
        #expect(section["idleAfterSeconds"]?.intValue == 60)
        #expect(section["windowSeconds"]?.intValue == 60)
        #expect(section["samples"]?.intValue == 3)
        #expect(section["windowsWithInput"]?.intValue == 0)
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

    /// scripts/cmux-next/idle-budget.py `saver_state` reads `policy.isSaver` (a bool) and then
    /// `policy.reason` or `inputs.reason`; with another key every saver session is refused.
    @Test func idleBudgetReadsPolicyIsSaverAndTheReason() async {
        let report = await Self.report()
        #expect(report["policy"]?["isSaver"] == JSONValue.bool(true))
        #expect(report["policy"]?["is_saver"] == nil)
        #expect(report["policy"]?["reason"]?.stringValue == "battery")
        #expect(report["inputs"]?["reason"]?.stringValue == "battery")
    }

    @Test func saverOffReportsNullReasonsAndNoCaps() async {
        let off = EnergyReport.State(policy: .normal, inputs: Self.inputs, wakeQueue: .init(entries: 0, coalescedFires: 0),
                                     cef: Self.state.cef)
        let report = await Self.report(state: off)
        #expect(report["policy"]?["isSaver"] == JSONValue.bool(false))
        #expect(report["policy"]?["reason"] == JSONValue.null)
        #expect(report["policy"]?["ambientMaxFPS"] == JSONValue.null)
        #expect(report["policy"]?["wakeAlignmentMs"]?.doubleValue == 8)
        #expect(report["inputs"]?["reason"] == JSONValue.null)
    }

    /// The default build: the `energySaver` feature is off, so low battery in `auto` leaves the saver off,
    /// and the report says why.
    @Test func featureOffWithLowBatteryReportsWhyTheSaverIsOff() async {
        var inputs = Self.inputs
        inputs.featureEnabled = false
        let state = EnergyReport.State(policy: EnergyPolicy(onBattery: true), inputs: inputs,
                                       wakeQueue: .init(entries: 0, coalescedFires: 0), cef: Self.state.cef)
        let report = await Self.report(state: state)
        #expect(report["policy"]?["isSaver"] == JSONValue.bool(false))
        #expect(report["inputs"]?["featureEnabled"] == JSONValue.bool(false))
        #expect(report["inputs"]?["batteryPercent"]?.intValue == 15)
        #expect(report["inputs"]?["setting"]?.stringValue == "auto")
    }

    /// `debug.energy.simulate`: the report says when the inputs are simulated, and the
    /// simulate method's `thermal` names are the ones the report gives.
    @Test func inputsSayWhetherTheyAreSimulated() async {
        #expect(await Self.report()["inputs"]?["simulated"] == JSONValue.bool(false))
        var state = Self.state
        state.inputs.simulated = true
        #expect(await Self.report(state: state)["inputs"]?["simulated"] == JSONValue.bool(true))
        for thermal in [ProcessInfo.ThermalState.nominal, .fair, .serious, .critical] {
            #expect(EnergyReport.Inputs.thermal(named: EnergyReport.Inputs.name(thermal)) == thermal)
        }
        #expect(EnergyReport.Inputs.thermal(named: "hot") == nil)
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
            return [.init(kind: "app", usage: Self.usage(pid: 1, interrupt: 10, packageIdle: 4, energy: 5))]
        }
        #expect(threads.seen == [false], "sampled on: \(threads.seen) (true = the main thread)")
        let process = report["processes"]?.arrayValue?.first
        #expect(process?["kind"]?.stringValue == "app")
        #expect(process?["name"]?.stringValue == "cmux")
        #expect(process?["interruptWakeups"]?.intValue == 10, "interrupt wakeups are not summed with package-idle ones")
        #expect(process?["packageIdleWakeups"]?.intValue == 4)
        #expect(process?["energyNj"]?.intValue == 5)
    }

    @Test func ledgerTopSumsReasonsPerOwnerAndKeepsTen() async {
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
        let rendered = await Self.report(ledger: ledger)["ledger_top"]?.arrayValue?.first
        #expect(rendered?["count"]?.intValue == 30)
        #expect(rendered?["perSecond"]?.doubleValue != nil)
    }

    /// `cef.energySaver` is `applied` only when the built engine says the fork took the last
    /// state; a refused or uncalled saver and no Chromium built yet are `unsupported`.
    @Test func cefEnergySaverIsAppliedOnlyWhenTheEngineSaysSo() async {
        #expect(EnergyReport.CEF.Saver(applied: true) == .applied)
        #expect(EnergyReport.CEF.Saver(applied: false) == .unsupported)
        #expect(EnergyReport.CEF.Saver(applied: nil) == .unsupported)
        for (applied, name) in [(true, "applied"), (false, "unsupported")] {
            var state = Self.state
            state.cef = .init(saver: .init(applied: applied), earlyPasses: nil)
            #expect(await Self.report(state: state)["cef"]?["energySaver"]?.stringValue == name)
        }
    }

    /// `tabs`: the sampled tab renderers, per tab. Two tabs on one renderer both show its
    /// whole usage and it names both. Only tab renderers count: an extension renderer (no client id) that a
    /// stale tab pid names is not one.
    @Test func tabsShowTheirRenderersUsageAndASharedRendererNamesEveryTab() throws {
        let renderer = { (pid: pid_t, client: Int32?, energy: UInt64) in
            EnergyReport.ProcessSample(kind: "cef-renderer", usage: Self.usage(pid: pid, interrupt: energy / 10, packageIdle: 1, energy: energy),
                                       rendererClientID: client)
        }
        let processes = [
            EnergyReport.ProcessSample(kind: "app", usage: Self.usage(pid: 1, interrupt: 1, packageIdle: 1, energy: 1)),
            renderer(501, 3, 9_000), renderer(502, 4, 300), renderer(503, nil, 70),
        ]
        let tabs = [
            ProcessUsage.TabRenderers(tab: "a", title: "Docs", pid: 501, rendererClients: [3]),
            ProcessUsage.TabRenderers(tab: "b", title: "Docs 2", pid: 501, rendererClients: [3]),
            ProcessUsage.TabRenderers(tab: "c", title: "Older fork", pid: nil, rendererClients: [4]),
            ProcessUsage.TabRenderers(tab: "d", title: "Stale", pid: 503, rendererClients: []),
        ]
        let grouped = EnergyReport.tabUsage(tabs, processes: processes)

        let rows = try #require(EnergyReport.render(state: Self.state, ledger: [], processes: processes, tabs: grouped)["tabs"]?.arrayValue)
        try #require(rows.count == 4)
        for row in rows.prefix(2) {
            #expect(row["energyNj"]?.intValue == 9_000)
            #expect(row["interruptWakeups"]?.intValue == 900)
            let shared = try #require(row["renderers"]?.arrayValue?.first)
            #expect(shared["pid"]?.intValue == 501)
            #expect(shared["clientId"]?.intValue == 3)
            #expect(shared["tabs"]?.arrayValue?.compactMap(\.stringValue) == ["a", "b"])
        }
        #expect(rows[0]["title"]?.stringValue == "Docs")
        #expect(rows[2]["renderers"]?.arrayValue?.first?["pid"]?.intValue == 502, "a client id alone attributes the renderer")
        #expect(rows[3]["renderers"]?.arrayValue?.isEmpty == true, "a process that is not a tab renderer is no tab's")
        #expect(rows[3]["energyNj"]?.intValue == 0)
    }

    @Test func noTabsGroupNothing() {
        let processes = [EnergyReport.ProcessSample(kind: "cef-renderer", usage: Self.usage(pid: 501, interrupt: 1, packageIdle: 1, energy: 1),
                                                    rendererClientID: 3)]
        #expect(EnergyReport.tabUsage([], processes: processes).isEmpty)
    }

    @Test func thermalStatesHaveStableNames() {
        let names = [ProcessInfo.ThermalState.nominal, .fair, .serious, .critical].map(EnergyReport.Inputs.name)
        #expect(names == ["nominal", "fair", "serious", "critical"])
    }

    /// One `RUSAGE_INFO_V6` sample carries CPU, the wakeups and the energy, so `debug.energy` and
    /// `debug.wakeups` read the same instant.
    @Test func oneSampleOfThisProcessCarriesTheEnergyCounters() throws {
        let me = try #require(ProcessUsage.sample(getpid()))
        #expect(me.pid == getpid())
        #expect(me.cpuNanos > 0)
        #expect(me.wakeups == me.interruptWakeups &+ me.packageIdleWakeups)
    }
}

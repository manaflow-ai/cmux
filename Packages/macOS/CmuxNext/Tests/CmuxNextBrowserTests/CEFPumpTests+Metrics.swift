@testable import CmuxNextBrowser
import CmuxNextMetrics
@testable import CmuxNextTrace
import Darwin
import Foundation
import Testing

/// The field histograms of p09-observability task 060: `cef.pump`, one sample per pass in us into the metrics of the
/// runtime the pump traces into (whatever the trace categories), and `cef.helper_exit`, one enumeration sample per
/// helper process that ended abnormally, the process type times 16 plus the reason (where each comes from:
/// CEFPumpTests+HelperExitRouting.swift). Each test records into its own store.
extension CEFPumpTests {
    /// A store of the two cef histograms, attached to `runtime`.
    static func store(on runtime: TraceRuntime) -> MetricsStore {
        let profile = MetricsProfile(appVersion: "1.0", buildNumber: "1", channel: "test", osVersion: "26.0", hardwareClass: "Mac16,10",
                                     bootSessionUUID: Array(0 ..< 16), buildUUID: Array(16 ..< 32),
                                     buildDay: MetricsProfile.Day(year: 2026, month: 10, day: 26))
        let store = MetricsStore(role: .app, profile: profile, pid: 4242, catalog: [.cefPump, .cefHelperExit])
        #expect(store.attach(to: runtime))
        return store
    }

    static func histogram(_ id: HistogramID, in store: MetricsStore) -> MetricsDelta.Histogram? {
        store.delta().histograms.first { $0.name == id.name }
    }

    // Binary fractions of a second, exact in a Double at 100 s: 3906.25 us and 15625 us.
    nonisolated private static let shortPassSeconds: TimeInterval = 1.0 / 256
    nonisolated private static let longPassSeconds: TimeInterval = 1.0 / 64

    @Test(arguments: [TraceCategories([.cef, .task]), TraceCategories.blackBox, []])
    func eachPassIsOneCefPumpSampleInMicroseconds(categories: TraceCategories) throws {
        let rig = Rig(categories: categories)
        let store = Self.store(on: rig.runtime)
        rig.work = { rig.seconds += Self.shortPassSeconds }
        rig.timer.fire() // the start's immediate pass
        rig.work = { rig.seconds += Self.longPassSeconds }
        rig.delayedPass(milliseconds: 7)
        let pump = try #require(Self.histogram(.cefPump, in: store))
        #expect(pump.count == 2, "one sample per pass, with or without a recording")
        #expect(pump.sum == 3_906 + 15_625)
        let layout = HistogramID.cefPump.layout
        #expect(pump.buckets.map(\.index) == [layout.bucketIndex(of: 3_906), layout.bucketIndex(of: 15_625)].compactMap { $0 })
        #expect(Self.histogram(.cefHelperExit, in: store) == nil)
    }

    @Test func aFireInsideAPassRecordsNoSampleOfItsOwn() throws {
        let rig = Rig()
        let store = Self.store(on: rig.runtime)
        var nested = true
        rig.work = {
            guard nested else { return }
            nested = false
            rig.timer.fire() // a menu's tracking loop inside CefDoMessageLoopWork
        }
        rig.timer.fire()
        #expect(rig.pump.stats.reentrantFires == 1)
        #expect(try #require(Self.histogram(.cefPump, in: store)).count == 1, "the outer pass only")
    }

    @Test func helperExitSamplesAreTheProcessTypeTimes16PlusTheReason() {
        #expect(CEFHelperExitMetric.sample(.renderer, .crashed) == 17)
        #expect(CEFHelperExitMetric.sample(.gpu, .killed) == 50)
        #expect(CEFHelperExitMetric.sample(.utility, .abnormal) == 70)
        #expect(CEFHelperExitMetric.sample(.other, .outOfMemory) == 3)
        let samples = CEFHelperExitMetric.ProcessType.allCases.flatMap { type in
            BrowserProcessExit.Reason.allCases.map { CEFHelperExitMetric.sample(type, $0) }
        }
        #expect(Set(samples).count == samples.count, "every type and reason has its own value")
        #expect(samples.allSatisfy { $0 > 0 && $0 < 256 && $0 % 16 != 0 }, "inside the layout, the reason nibble never 0")
    }

    @Test func helperTypesComeFromChromiumsTypeSwitch() {
        typealias Kind = CEFHelperExitMetric.ProcessType
        #expect(Kind(processType: "renderer", isExtension: false) == .renderer)
        #expect(Kind(processType: "renderer", isExtension: true) == .extensionRenderer)
        #expect(Kind(processType: "gpu-process", isExtension: false) == .gpu)
        #expect(Kind(processType: "utility", isExtension: false) == .utility)
        #expect(Kind(processType: "crashpad-handler", isExtension: false) == .other)
    }

    @Test func aHelperExitRecordsOneEnumerationSampleInItsBucket() throws {
        let runtime = TraceRuntime(role: .app)
        let store = Self.store(on: runtime)
        let exits = CEFHelperExitMetric(metrics: Metrics(runtime: runtime))
        exits.record(.gpu, .crashed)
        exits.record(.gpu, .crashed)
        exits.record(.renderer, .killed)
        let histogram = try #require(Self.histogram(.cefHelperExit, in: store))
        #expect(histogram.count == 3)
        let layout = HistogramID.cefHelperExit.layout
        let gpuCrash = try #require(layout.bucketIndex(of: 49))
        let rendererKill = try #require(layout.bucketIndex(of: 18))
        #expect(histogram.buckets.map(\.index) == [rendererKill, gpuCrash].sorted())
        #expect(histogram.buckets.first { $0.index == gpuCrash }?.count == 2)
        #expect(Self.histogram(.cefPump, in: store) == nil)
    }

    @Test func onlyAnAbnormalEndIsAHelperExit() {
        func reason(_ status: Int32) -> BrowserProcessExit.Reason? {
            CEFChildProcessMonitor.Exit(pid: 1, processType: "gpu-process", subType: nil, isExtension: false, status: status).abnormalReason
        }
        #expect(reason(0) == nil, "exit 0")
        #expect(reason(1 << 8) == .abnormal, "exit 1")
        #expect(reason(SIGTERM) == nil, "Chromium ends helpers it no longer needs with SIGTERM")
        #expect(reason(SIGKILL) == .killed)
        #expect(reason(SIGSEGV) == .crashed)
        #expect(reason(0x7f | (SIGSTOP << 8)) == nil, "stopped, not ended")
    }
}

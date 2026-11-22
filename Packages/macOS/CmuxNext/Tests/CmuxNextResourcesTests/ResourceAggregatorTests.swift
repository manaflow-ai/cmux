import Foundation
import Testing
@testable import CmuxNextResources

private let second: UInt64 = 1_000_000_000
private let mib: UInt64 = 1_048_576

private func sample(_ pid: Int32, cpu: UInt64, memory: UInt64, at time: UInt64, host: String = ProcessKey.localHost) -> ProcessSample {
    ProcessSample(key: ProcessKey(host: host, pid: pid), name: "p\(pid)", cpuNanos: cpu, memoryBytes: memory, sampledAtNanos: time)
}

private func set(_ tabs: [TabResourceSources], shared: [SharedProcess] = [], _ samples: [ProcessSample]) -> ResourceSampleSet {
    ResourceSampleSet(tabs: tabs, shared: shared, samples: Dictionary(uniqueKeysWithValues: samples.map { ($0.key, $0) }))
}

private func tab(_ id: String, _ pids: [Int32], kind: TabResourceKind = .terminal, estimate: UInt64 = 0) -> TabResourceSources {
    TabResourceSources(tabID: id, title: id, kind: kind, processes: pids.map { ProcessKey(pid: $0) }, estimatedAppBytes: estimate)
}

@Suite struct ResourceAggregatorTests {
    @Test func aProcessSharedByTwoTabsCountsOnceInTheTotal() {
        // Two Chromium tabs of one site share renderer 30.
        let tabs = [tab("a", [30], kind: .chromium), tab("b", [30, 31], kind: .chromium)]
        let report = ResourceAggregator.report(
            current: set(tabs, [sample(30, cpu: 0, memory: 100 * mib, at: 0), sample(31, cpu: 0, memory: 50 * mib, at: 0)]),
            previous: nil
        )
        #expect(report.tabs.map(\.usage.memoryBytes) == [100 * mib, 150 * mib])
        #expect(report.total.memoryBytes == 150 * mib)
        #expect(report.processCount == 2)
        #expect(report.tabs.map(\.sharedWithTabs) == [1, 1])
    }

    @Test func sharedProcessesAreNeverAddedToATabOrTheTotal() {
        let gpu = SharedProcess(key: ProcessKey(pid: 90), role: .gpu)
        let network = SharedProcess(key: ProcessKey(pid: 91), role: .network)
        let app = SharedProcess(key: ProcessKey(pid: 1), role: .app)
        // A tab that (wrongly) lists the GPU process still does not count it.
        let tabs = [tab("a", [30, 90], kind: .chromium), tab("b", [40])]
        let samples = [
            sample(30, cpu: 0, memory: 100 * mib, at: 0), sample(40, cpu: 0, memory: 10 * mib, at: 0),
            sample(90, cpu: 0, memory: 300 * mib, at: 0), sample(91, cpu: 0, memory: 20 * mib, at: 0),
            sample(1, cpu: 0, memory: 150 * mib, at: 0),
        ]
        let report = ResourceAggregator.report(current: set(tabs, shared: [network, gpu, app], samples), previous: nil)
        #expect(report.tabs[0].usage.memoryBytes == 100 * mib)
        #expect(report.tabs[0].processCount == 1)
        #expect(report.total.memoryBytes == 110 * mib)
        #expect(report.shared.memoryBytes == 470 * mib)
        #expect(report.sharedRoles == [.app, .gpu, .network])
    }

    @Test func cpuNeedsTwoSamplesAndUsesEachProcessesOwnInterval() {
        let tabs = [tab("a", [10, 11])]
        let first = set(tabs, [sample(10, cpu: 1 * second, memory: mib, at: 5 * second)])
        let firstReport = ResourceAggregator.report(current: first, previous: nil)
        #expect(firstReport.tabs[0].usage.cpu == nil)
        #expect(firstReport.total.cpu == nil)

        // 10 used 0.5 s of CPU in 1 s; 11 is new and adds no CPU yet.
        let second2 = set(tabs, [
            sample(10, cpu: 1 * second + second / 2, memory: mib, at: 6 * second),
            sample(11, cpu: 3 * second, memory: mib, at: 6 * second),
        ])
        let report = ResourceAggregator.report(current: second2, previous: first)
        #expect(report.tabs[0].usage.cpu == 0.5)
        #expect(report.total.cpu == 0.5)
        #expect(report.tabs[0].usage.memoryBytes == 2 * mib)
    }

    @Test func pidsOnDifferentHostsAreDifferentProcesses() {
        let local = TabResourceSources(tabID: "l", title: "l", kind: .terminal, processes: [ProcessKey(pid: 7)])
        let remote = TabResourceSources(tabID: "r", title: "r", kind: .terminal, processes: [ProcessKey(host: "vm1", pid: 7)])
        let report = ResourceAggregator.report(
            current: set([local, remote], [sample(7, cpu: 0, memory: mib, at: 0), sample(7, cpu: 0, memory: 2 * mib, at: 0, host: "vm1")]),
            previous: nil
        )
        #expect(report.total.memoryBytes == 3 * mib)
        #expect(report.tabs.map(\.sharedWithTabs) == [0, 0])
    }

    @Test func appEstimatesAddToTheirTabAndOnceToTheTotal() {
        let tabs = [tab("a", [10], estimate: 20 * mib), tab("b", [], estimate: 5 * mib)]
        let report = ResourceAggregator.report(current: set(tabs, [sample(10, cpu: 0, memory: mib, at: 0)]), previous: nil)
        #expect(report.tabs.map(\.usage.memoryBytes) == [21 * mib, 5 * mib])
        #expect(report.total.memoryBytes == 26 * mib)
    }

    @Test func goneProcessesAndPidReuseAddNothing() {
        let tabs = [tab("a", [10, 12])]
        let previous = set(tabs, [sample(10, cpu: 5 * second, memory: mib, at: 0)])
        // 10 restarted under the same pid (counter went back); 12 has no sample.
        let current = set(tabs, [sample(10, cpu: second, memory: mib, at: second)])
        let report = ResourceAggregator.report(current: current, previous: previous)
        #expect(report.tabs[0].usage.cpu == 0)
        #expect(report.tabs[0].processCount == 1)
    }

    @Test func topConsumersRankByCpuThenMemory() {
        let tabs = [tab("idle-small", [1]), tab("busy", [2]), tab("idle-big", [3])]
        let previous = set(tabs, [
            sample(1, cpu: 0, memory: mib, at: 0), sample(2, cpu: 0, memory: mib, at: 0), sample(3, cpu: 0, memory: 9 * mib, at: 0),
        ])
        let current = set(tabs, [
            sample(1, cpu: 0, memory: mib, at: second), sample(2, cpu: second / 4, memory: mib, at: second),
            sample(3, cpu: 0, memory: 9 * mib, at: second),
        ])
        let report = ResourceAggregator.report(current: current, previous: previous)
        #expect(report.topConsumers(2).map(\.id) == ["busy", "idle-big"])
    }

    @Test func aLoneTabIsNotRepeatedUnderTheTotal() {
        let one = [tab("~", [1])]
        let lone = ResourceAggregator.report(
            current: set(one, [sample(1, cpu: 0, memory: mib, at: second)]),
            previous: set(one, [sample(1, cpu: 0, memory: mib, at: 0)])
        )
        #expect(lone.breakdown(3).isEmpty)

        let two = [tab("~", [1]), tab("server", [2])]
        let pair = ResourceAggregator.report(
            current: set(two, [sample(1, cpu: 0, memory: mib, at: second), sample(2, cpu: 0, memory: 2 * mib, at: second)]),
            previous: set(two, [sample(1, cpu: 0, memory: mib, at: 0), sample(2, cpu: 0, memory: 2 * mib, at: 0)])
        )
        #expect(pair.breakdown(3).map(\.id) == ["server", "~"])
    }

    @Test func formatsLikeActivityMonitor() {
        #expect(ResourceFormat.cpu(0.123, locale: Locale(identifier: "en_US")) == "12.3%")
        #expect(ResourceFormat.cpu(2.5, locale: Locale(identifier: "en_US")) == "250.0%")
        #expect(ResourceFormat.memory(145 * mib).contains("MB"))
    }
}

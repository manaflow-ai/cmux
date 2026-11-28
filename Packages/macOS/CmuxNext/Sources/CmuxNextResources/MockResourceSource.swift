import Foundation

/// Fake numbers for demos and previews: every tab gets one process whose
/// CPU time grows by a fixed rate per call.
@MainActor
public final class MockResourceSource: ResourceSampleSource {
    public var tabs: [TabResourceSources]
    private var calls: UInt64 = 0

    public init(tabs: [TabResourceSources]) {
        self.tabs = tabs
    }

    public func sample(_ target: ResourceTarget) async -> ResourceSampleSet {
        calls += 1
        let now = calls * 1_000_000_000
        let chosen: [TabResourceSources] = switch target {
        case .tab(let id): tabs.filter { $0.tabID == id }
        case .workspace: tabs
        }
        var samples: [ProcessKey: ProcessSample] = [:]
        for (index, tab) in chosen.enumerated() {
            for key in tab.processes {
                let rate = UInt64(index + 1) * 20_000_000
                samples[key] = ProcessSample(key: key, name: tab.title, cpuNanos: rate * calls,
                                             memoryBytes: UInt64(index + 1) * 48 * 1_048_576, sampledAtNanos: now)
            }
        }
        let app = ProcessKey(pid: 1)
        samples[app] = ProcessSample(key: app, name: "cmux", cpuNanos: 5_000_000 * calls, memoryBytes: 120 * 1_048_576, sampledAtNanos: now)
        return ResourceSampleSet(tabs: chosen, shared: [SharedProcess(key: app, role: .app)], samples: samples)
    }
}

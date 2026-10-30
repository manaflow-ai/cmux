import CmuxNextResources
import CmuxNextWakeups
import Foundation

/// The Task Manager's samples: every tab and the shared processes through
/// ``AppResourceSource`` (``ResourceTarget/everything``), plus this Mac's
/// cmux-tui daemons. Runs only while a Task Manager page is open.
@MainActor
final class AppTaskManagerSource: TaskManagerSampleSource {
    private weak var services: AppServices?

    init(services: AppServices) {
        self.services = services
    }

    /// The pids of this Mac's connected daemons.
    var localDaemonPIDs: Set<Int32> {
        guard let services else { return [] }
        return Set(services.machines.daemons.filter(\.isLocal).compactMap { $0.identity?.pid }.filter { $0 > 0 })
    }

    func sample() async -> TaskManagerSampleSet {
        guard let services else { return .empty }
        var resources = await services.resources.sample(.everything)
        let daemons = localDaemonPIDs.sorted().map { ProcessKey(pid: $0) }
        for (key, sample) in await Self.sampleLocal(daemons.map(\.pid)) { resources.samples[key] = sample }
        return TaskManagerSampleSet(resources: resources, daemons: daemons)
    }

    @concurrent
    private static func sampleLocal(_ pids: [Int32]) async -> [ProcessKey: ProcessSample] {
        var samples: [ProcessKey: ProcessSample] = [:]
        for pid in pids {
            guard let usage = ProcessUsage.sample(pid) else { continue }
            let key = ProcessKey(pid: pid)
            samples[key] = ProcessSample(key: key, name: usage.name, cpuNanos: usage.cpuNanos,
                                         memoryBytes: usage.physFootprint, sampledAtNanos: usage.uptimeNanos)
        }
        return samples
    }
}

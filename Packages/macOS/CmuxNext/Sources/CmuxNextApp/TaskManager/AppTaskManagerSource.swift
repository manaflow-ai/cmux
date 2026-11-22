import CmuxNextResources
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
        for (key, sample) in await ProcessSample.sampleLocal(daemons.map(\.pid)) { resources.samples[key] = sample }
        return TaskManagerSampleSet(resources: resources, daemons: daemons)
    }
}

import Foundation

/// Owns user-requested inventory refreshes for one panel, coalescing a burst
/// for the same machine while allowing independent machines to refresh.
@MainActor
final class CloudMachineRefreshCoordinator {
    private let operation: @MainActor (SurfaceMachineID) async -> Void
    private var tasks: [SurfaceMachineID: Task<Void, Never>] = [:]
    private var generation: UInt64 = 0

    init(operation: @escaping @MainActor (SurfaceMachineID) async -> Void) {
        self.operation = operation
    }

    func refresh(_ machine: SurfaceMachineID) {
        guard tasks[machine] == nil else { return }
        let generation = generation
        tasks[machine] = Task { [weak self, operation] in
            guard !Task.isCancelled else { return }
            await operation(machine)
            guard let self, self.generation == generation else { return }
            self.tasks[machine] = nil
        }
    }

    func cancelAll() {
        generation &+= 1
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
    }

    deinit {
        for task in tasks.values { task.cancel() }
    }
}

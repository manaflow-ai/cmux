import Foundation

/// Coalesces admitted notifications until the next main-actor turn. Each machine
/// builds its organization input once per batch; repeated terminals keep only
/// their newest position in delivery order. No timer or second event stream.
@MainActor
final class CloudSidebarNotificationCoordinator {
    private var pending: [SurfaceMachineID: [SurfaceResourceID]] = [:]
    private var task: Task<Void, Never>?
    private let apply: @MainActor (SurfaceMachineID, [SurfaceResourceID]) -> Void

    init(apply: @escaping @MainActor (SurfaceMachineID, [SurfaceResourceID]) -> Void) {
        self.apply = apply
    }

    deinit { task?.cancel() }

    func enqueue(_ resource: SurfaceResourceID) {
        guard !resource.machine.isLocal else { return }
        pending[resource.machine, default: []].removeAll { $0 == resource }
        pending[resource.machine, default: []].append(resource)
        guard task == nil else { return }
        task = Task { [weak self] in self?.flush() }
    }

    func flush() {
        let batch = pending
        pending.removeAll(keepingCapacity: true)
        task = nil
        for machine in batch.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            if let resources = batch[machine] { apply(machine, resources) }
        }
    }
}

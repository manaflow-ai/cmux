import Combine
import Foundation

/// Accumulates changed workspace identities across a merged observation burst.
@MainActor
final class SidebarWorkspaceObservationBatch {
    private var workspaceIds: Set<UUID> = []

    /// Coalesces wakeups while retaining every workspace identity seen upstream.
    ///
    /// `coalesceLatest` guarantees a bounded trailing cadence during sustained
    /// input and honors downstream demand. Identity accumulation deliberately
    /// happens before that operator: if an async consumer temporarily has no
    /// demand, only its wakeup may be conflated; the keyed changes themselves
    /// remain pending until the next delivery.
    static func mergedChanges(
        from publishers: [AnyPublisher<UUID, Never>],
        for interval: RunLoop.SchedulerTimeType.Stride
    ) -> AnyPublisher<Set<UUID>, Never> {
        mergedChanges(from: publishers, for: interval, scheduler: RunLoop.main)
    }

    /// Coalesces on an injected scheduler so callers can control the delivery clock.
    static func mergedChanges<Context: Scheduler>(
        from publishers: [AnyPublisher<UUID, Never>],
        for interval: Context.SchedulerTimeType.Stride,
        scheduler: Context
    ) -> AnyPublisher<Set<UUID>, Never> {
        let batch = SidebarWorkspaceObservationBatch()
        return Publishers.MergeMany(publishers)
            .receive(on: scheduler)
            .handleEvents(receiveOutput: { batch.insert($0) })
            .coalesceLatest(for: interval, scheduler: scheduler)
            .map { _ in batch.take() }
            .filter { !$0.isEmpty }
            .eraseToAnyPublisher()
    }

    func insert(_ workspaceId: UUID) {
        workspaceIds.insert(workspaceId)
    }

    func take() -> Set<UUID> {
        defer { workspaceIds.removeAll(keepingCapacity: true) }
        return workspaceIds
    }
}

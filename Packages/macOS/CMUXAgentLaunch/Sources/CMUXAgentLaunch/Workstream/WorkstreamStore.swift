import Foundation
import Observation

/// Immutable state emitted by ``WorkstreamCore`` for rendering on the main actor.
public struct WorkstreamStoreSnapshot: Sendable, Equatable {
    public let items: [WorkstreamItem]
    public let hasMorePersistedItems: Bool
    public let isLoadingOlderItems: Bool

    public init(items: [WorkstreamItem], hasMorePersistedItems: Bool, isLoadingOlderItems: Bool) {
        self.items = items
        self.hasMorePersistedItems = hasMorePersistedItems
        self.isLoadingOlderItems = isLoadingOlderItems
    }

    public var pending: [WorkstreamItem] { items.filter { $0.status.isPending } }
    public var actionable: [WorkstreamItem] { items.filter { $0.kind.isActionable } }
}

/// Main-actor projection of the actor-owned Feed state.
@MainActor
@Observable
public final class WorkstreamStore {
    public private(set) var items: [WorkstreamItem] = []
    public private(set) var hasMorePersistedItems = false
    public private(set) var isLoadingOlderItems = false

    public var pending: [WorkstreamItem] { items.filter { $0.status.isPending } }
    public var actionable: [WorkstreamItem] { items.filter { $0.kind.isActionable } }

    nonisolated let core: WorkstreamCore
    private var snapshotTask: Task<Void, Never>?

    public init(
        transport: any WorkstreamTransport = NullWorkstreamTransport(),
        persistence: WorkstreamPersistence? = nil,
        ringCapacity: Int = WorkstreamDefaultRingCapacity,
        initialLoadLimit: Int = WorkstreamDefaultInitialLoadLimit,
        historyPageSize: Int = WorkstreamDefaultHistoryPageSize,
        clock: @escaping @Sendable () -> Date = { Date() },
        workstreamIDNormalizer: @escaping @Sendable (String, String) -> String = { rawValue, _ in rawValue },
        titleProvider: @escaping @Sendable (WorkstreamEvent) -> String? = { _ in nil }
    ) {
        core = WorkstreamCore(
            transport: transport,
            persistence: persistence,
            ringCapacity: ringCapacity,
            initialLoadLimit: initialLoadLimit,
            historyPageSize: historyPageSize,
            clock: clock,
            workstreamIDNormalizer: workstreamIDNormalizer,
            titleProvider: titleProvider
        )
        snapshotTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for await snapshot in await self.core.snapshots() {
                self.apply(snapshot)
            }
        }
    }

    public func start() async {
        await core.start()
        await core.expireAbandonedItems()
        apply(await core.snapshot())
    }

    public func loadOlderItems() async {
        await core.loadOlderItems()
        apply(await core.snapshot())
    }

    /// Ingests an event on ``WorkstreamCore`` and returns the authoritative item.
    @discardableResult
    public func ingestReturningItem(_ event: WorkstreamEvent) async -> WorkstreamItem? {
        let item = await core.ingestReturningItem(event)
        apply(await core.snapshot())
        return item
    }

    public func ingest(_ event: WorkstreamEvent) async {
        _ = await ingestReturningItem(event)
    }

    /// Bridges the synchronous Feed ingress contract to the actor without
    /// running decoding, indexing, or persistence on the main actor.
    ///
    /// This is called only by the ordered ingress worker, never by SwiftUI.
    nonisolated func ingestFromIngress(_ event: WorkstreamEvent) -> WorkstreamItem? {
        let slot = IngressResultSlot()
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            slot.value = await core.ingestReturningItem(event)
            semaphore.signal()
        }
        semaphore.wait()
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.apply(await self.core.snapshot())
        }
        return slot.value
    }

    public func send(_ action: WorkstreamAction) async throws {
        try await core.send(action)
        apply(await core.snapshot())
    }

    public func markResolved(_ itemId: UUID, decision: WorkstreamDecision) async {
        await core.markResolved(itemId, decision: decision)
        apply(await core.snapshot())
    }

    public func markResolved(requestId: String, decision: WorkstreamDecision) async {
        await core.markResolved(requestId: requestId, decision: decision)
        apply(await core.snapshot())
    }

    public func markExpired(_ itemId: UUID) async {
        await core.markExpired(itemId)
        apply(await core.snapshot())
    }

    public func expirePending(olderThan threshold: TimeInterval) async {
        await core.expirePending(olderThan: threshold)
        apply(await core.snapshot())
    }

    public func expireItems(forPpid ppid: Int) async {
        await core.expireItems(forPpid: ppid)
        apply(await core.snapshot())
    }

    public func expireAbandonedItems(isProcessAlive: @escaping @Sendable (Int) -> Bool = WorkstreamCore.defaultIsProcessAlive) async {
        await core.expireAbandonedItems(isProcessAlive: isProcessAlive)
        apply(await core.snapshot())
    }

    public func snapshot() -> WorkstreamStoreSnapshot {
        WorkstreamStoreSnapshot(items: items, hasMorePersistedItems: hasMorePersistedItems, isLoadingOlderItems: isLoadingOlderItems)
    }

    private func apply(_ snapshot: WorkstreamStoreSnapshot) {
        items = snapshot.items
        hasMorePersistedItems = snapshot.hasMorePersistedItems
        isLoadingOlderItems = snapshot.isLoadingOlderItems
    }
}

/// Synchronous ingress bridge storage; the semaphore establishes happens-before ordering.
private final class IngressResultSlot: @unchecked Sendable {
    var value: WorkstreamItem?
}

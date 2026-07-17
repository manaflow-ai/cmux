import CMUXAgentLaunch
import Observation

/// Builds the process-wide Feed projection once per Workstream mutation.
@MainActor
@Observable
final class FeedPresentationStore {
    private(set) var items: [WorkstreamItem] = []
    private(set) var presentation = FeedPresentationSnapshot.empty
    private(set) var hasMorePersistedItems = false
    private(set) var isLoadingOlderItems = false

    @ObservationIgnored private weak var source: WorkstreamStore?
    @ObservationIgnored private var observationGeneration = 0

    func install(source: WorkstreamStore) {
        self.source = source
        observationGeneration &+= 1
        armItemsObservation(generation: observationGeneration)
        armPagingObservation(generation: observationGeneration)
    }

    func loadOlderItems() async {
        await source?.loadOlderItems()
    }

    private func armItemsObservation(generation: Int) {
        guard generation == observationGeneration, let source else { return }
        withObservationTracking {
            let sourceItems = source.items
            items = sourceItems
            presentation = Self.makePresentation(items: sourceItems)
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.armItemsObservation(generation: generation)
            }
        }
    }

    private func armPagingObservation(generation: Int) {
        guard generation == observationGeneration, let source else { return }
        withObservationTracking {
            hasMorePersistedItems = source.hasMorePersistedItems
            isLoadingOlderItems = source.isLoadingOlderItems
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.armPagingObservation(generation: generation)
            }
        }
    }

    private static func makePresentation(items: [WorkstreamItem]) -> FeedPresentationSnapshot {
        var lastPromptByWorkstream: [String: String] = [:]
        for item in items {
            if case .userPrompt(let text) = item.payload, !text.isEmpty {
                lastPromptByWorkstream[item.workstreamId] = text
            }
        }

        var actionable: [FeedItemSnapshot] = []
        var activityStable: [FeedItemSnapshot] = []
        var activityHistory: [FeedItemSnapshot] = []
        actionable.reserveCapacity(items.count)
        activityStable.reserveCapacity(items.count)
        activityHistory.reserveCapacity(items.count)

        for item in items.reversed() {
            let snapshot = FeedItemSnapshot(
                item: item,
                userPromptEcho: lastPromptByWorkstream[item.workstreamId]
            )
            if item.kind.isActionable {
                actionable.append(snapshot)
            }
            guard item.kind.isActionable || item.kind == .todos || item.kind == .stop else {
                continue
            }
            if snapshot.status.isPending || snapshot.kind == .stop {
                activityStable.append(snapshot)
            } else {
                activityHistory.append(snapshot)
            }
        }
        return FeedPresentationSnapshot(
            actionable: actionable,
            activity: FeedActivitySnapshotGroups(
                stable: activityStable,
                history: activityHistory
            )
        )
    }
}

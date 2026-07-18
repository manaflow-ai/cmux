import CMUXAgentLaunch
import Observation

/// Builds the process-wide Feed projection once per Workstream mutation.
@MainActor
@Observable
final class FeedPresentationStore {
    private(set) var items: [WorkstreamItem] = []
    private(set) var presentation = FeedPresentationSnapshot.empty

    @ObservationIgnored private weak var source: WorkstreamStore?
    @ObservationIgnored private var observationGeneration = 0

    func install(source: WorkstreamStore) {
        self.source = source
        observationGeneration &+= 1
        armItemsObservation(generation: observationGeneration)
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

    private static func makePresentation(items: [WorkstreamItem]) -> FeedPresentationSnapshot {
        var actionable: [FeedItemSnapshot] = []
        actionable.reserveCapacity(items.count)
        for item in items.reversed() where item.kind.isActionable {
            actionable.append(FeedItemSnapshot(
                item: item,
                userPromptEcho: item.context?.lastUserMessage
            ))
        }
        return FeedPresentationSnapshot(actionable: actionable)
    }
}

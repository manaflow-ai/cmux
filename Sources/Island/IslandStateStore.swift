// Sources/Island/IslandStateStore.swift

import Combine
import Foundation

/// Concrete `IslandStateProvider` that projects an `IslandStateSource` into
/// a sorted, debounced `[IslandSession]` publisher the view observes.
///
/// The store itself does no model reading — all data comes via the source,
/// which is either the production `TabManagerIslandStateSource` (added in
/// Task 6) or a test/debug fake such as `InMemoryIslandStateSource`.
@MainActor
final class IslandStateStore: IslandStateProvider, ObservableObject {

    private let source: IslandStateSource
    private let subject: CurrentValueSubject<[IslandSession], Never>
    private var cancellable: AnyCancellable?

    init(source: IslandStateSource) {
        self.source = source
        let initial = source.makeSnapshot().sorted(by: <)
        self.subject = CurrentValueSubject(initial)

        // Debounce 50ms so back-to-back set-status/notify bursts coalesce
        // into a single emission instead of one per upstream tick.
        self.cancellable = source.changes
            .debounce(for: .milliseconds(50), scheduler: DispatchQueue.main)
            .sink { [weak self] in
                guard let self else { return }
                let snapshot = self.source.makeSnapshot().sorted(by: <)
                self.subject.send(snapshot)
            }
    }

    var sessionsPublisher: AnyPublisher<[IslandSession], Never> {
        subject.eraseToAnyPublisher()
    }

    var currentSessions: [IslandSession] {
        subject.value
    }
}

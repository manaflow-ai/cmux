import CmuxFoundation
import CMUXAgentLaunch
import Foundation
import Observation

/// Projects the observable Workstream store into a stable panel snapshot.
@MainActor
@Observable
final class FeedPanelViewModel {
    private(set) var items: [WorkstreamItem] = []
    private(set) var hasMorePersistedItems = false
    private(set) var isLoadingOlderItems = false
    private var storeInstalledObserver: NSObjectProtocol?

    init() {
        storeInstalledObserver = NotificationCenter.default.addObserver(
            forName: FeedCoordinator.storeInstalledNotification,
            object: FeedCoordinator.shared,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.arm()
            }
        }
        arm()
    }

    isolated deinit {
        if let storeInstalledObserver {
            NotificationCenter.default.removeObserver(storeInstalledObserver)
        }
    }

    private func arm() {
        guard let store = FeedCoordinator.shared.store else { return }
        withObservationTracking {
            items = store.items
            hasMorePersistedItems = store.hasMorePersistedItems
            isLoadingOlderItems = store.isLoadingOlderItems
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.arm()
            }
        }
    }

    nonisolated func loadOlderItems() {
        Task { @MainActor [weak self] in
            guard let self, !self.isLoadingOlderItems, self.hasMorePersistedItems else { return }
            await FeedCoordinator.shared.store?.loadOlderItems()
        }
    }
}

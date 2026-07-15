import CmuxFoundation
import CMUXAgentLaunch
import Foundation
import Observation
import SwiftUI

/// Projects the shared Workstream store into immutable Feed snapshots.
@MainActor
@Observable
final class FeedPanelViewModel {
    private(set) var items: [WorkstreamItem] = []
    private(set) var hasMorePersistedItems = false
    private(set) var isLoadingOlderItems = false

    @ObservationIgnored private let coordinator: FeedCoordinator
    @ObservationIgnored private var storeInstallTask: Task<Void, Never>?
    @ObservationIgnored private var loadOlderTask: Task<Void, Never>?

    init(
        coordinator: FeedCoordinator = .shared,
        notificationCenter: NotificationCenter = .default
    ) {
        self.coordinator = coordinator
        arm()
        storeInstallTask = Task { @MainActor [weak self, weak coordinator] in
            guard let coordinator else { return }
            for await _ in notificationCenter.notifications(
                named: FeedCoordinator.storeInstalledNotification,
                object: coordinator
            ) {
                guard !Task.isCancelled, let self else { return }
                self.arm()
            }
        }
    }

    deinit {
        storeInstallTask?.cancel()
        loadOlderTask?.cancel()
    }

    private func arm() {
        guard let store = coordinator.store else { return }
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

    func loadOlderItems() {
        guard !isLoadingOlderItems,
              hasMorePersistedItems,
              let store = coordinator.store else { return }
        loadOlderTask?.cancel()
        loadOlderTask = Task { @MainActor in
            await store.loadOlderItems()
        }
    }
}

struct FeedHistoryLoadMoreRow: View {
    let isLoading: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.6)
                        .frame(width: 12, height: 12)
                }
                Text(label)
                    .cmuxFont(size: 11, weight: .medium)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
        .disabled(isLoading)
    }

    private var label: String {
        if isLoading {
            return String(localized: "feed.history.loadingOlder", defaultValue: "Loading older activity...")
        }
        return String(localized: "feed.history.loadOlder", defaultValue: "Load older activity")
    }

}

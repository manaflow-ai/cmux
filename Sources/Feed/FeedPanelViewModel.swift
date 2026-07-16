import CmuxFoundation
import CMUXAgentLaunch
import Foundation
import Observation
import SwiftUI

/// Projects the shared `WorkstreamStore` into immutable Feed snapshots for
/// SwiftUI. Observation owns rendering; the only task is a cancellable history
/// request whose lifetime is tied to this model.
@MainActor
@Observable
final class FeedPanelViewModel {
    private(set) var items: [WorkstreamItem] = []
    private(set) var hasMorePersistedItems = false
    private(set) var isLoadingOlderItems = false
    @ObservationIgnored private var storeInstalledObserver: NSObjectProtocol?
    @ObservationIgnored private var loadOlderTask: Task<Void, Never>?

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

    deinit {
        loadOlderTask?.cancel()
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

    func loadOlderItems() {
        guard !isLoadingOlderItems,
              hasMorePersistedItems,
              let store = FeedCoordinator.shared.store else { return }
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

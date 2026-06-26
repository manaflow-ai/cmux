import CMUXAgentLaunch
import Foundation
import Observation
import SwiftUI

/// Mirrors the `@Observable` WorkstreamStore into an `@Observable`
/// snapshot so SwiftUI reliably re-renders the Feed panel on every
/// mutation.
@MainActor
@Observable
final class FeedPanelViewModel {
    private(set) var items: [WorkstreamItem] = []
    private(set) var hasMorePersistedItems = false
    private(set) var isLoadingOlderItems = false
    @ObservationIgnored private var storeInstalledObserver: NSObjectProtocol?

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
                    .font(.system(size: 11, weight: .medium))
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

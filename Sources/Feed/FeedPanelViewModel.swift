import CmuxFoundation
import CMUXAgentLaunch
import Foundation
import Observation
import SwiftUI

/// Mirrors the process-wide Feed projection into one panel's observable state.
@MainActor
@Observable
final class FeedPanelViewModel {
    private(set) var items: [WorkstreamItem] = []
    private(set) var presentation = FeedPresentationSnapshot.empty
    private(set) var hasMorePersistedItems = false
    private(set) var isLoadingOlderItems = false

    @ObservationIgnored private let presentationStore: FeedPresentationStore
    @ObservationIgnored private var loadOlderTask: Task<Void, Never>?

    init(coordinator: FeedCoordinator = .shared) {
        self.presentationStore = coordinator.presentationStore
        arm()
    }

    deinit {
        loadOlderTask?.cancel()
    }

    private func arm() {
        withObservationTracking {
            items = presentationStore.items
            presentation = presentationStore.presentation
            hasMorePersistedItems = presentationStore.hasMorePersistedItems
            isLoadingOlderItems = presentationStore.isLoadingOlderItems
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.arm()
            }
        }
    }

    func loadOlderItems() {
        guard !isLoadingOlderItems,
              hasMorePersistedItems else { return }
        loadOlderTask?.cancel()
        loadOlderTask = Task { @MainActor in
            await presentationStore.loadOlderItems()
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

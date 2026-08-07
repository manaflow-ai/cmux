import CmuxFoundation
import CMUXAgentLaunch
import Foundation
import Observation
import SwiftUI

/// Bridges the `@Observable` WorkstreamStore to a Combine `@Published`
/// snapshot so SwiftUI reliably re-renders the Feed panel on every
/// mutation.
@MainActor
final class FeedPanelViewModel: ObservableObject {
    @Published private(set) var items: [WorkstreamItem] = []
    @Published private(set) var sessionTitlesByWorkstream: [String: String] = [:]
    @Published private(set) var hasMorePersistedItems = false
    @Published private(set) var isLoadingOlderItems = false
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

    deinit {
        if let storeInstalledObserver {
            NotificationCenter.default.removeObserver(storeInstalledObserver)
        }
    }

    private func arm() {
        guard let store = FeedCoordinator.shared.store else { return }
        withObservationTracking {
            let nextItems = store.items
            items = nextItems
            sessionTitlesByWorkstream = Dictionary(
                uniqueKeysWithValues: Set(nextItems.map(\.workstreamId)).compactMap { workstreamId in
                    FeedCoordinator.shared.sessionDisplayTitle(workstreamId: workstreamId)
                        .map { (workstreamId, $0) }
                }
            )
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

    /// Pending decisions for the Actionable filter, newest first.
    nonisolated static func actionableItems(_ items: [WorkstreamItem]) -> [WorkstreamItem] {
        items.reversed().filter { $0.kind.isActionable && $0.status.isPending }
    }

    /// One current card per agent session for the All Activity filter.
    /// A new user prompt retires the previous turn's card until fresh
    /// session activity arrives, so stale Stop rows never remain replyable.
    nonisolated static func activityItems(_ items: [WorkstreamItem]) -> [WorkstreamItem] {
        var latestByWorkstream: [String: (offset: Int, item: WorkstreamItem)] = [:]
        for (offset, item) in items.enumerated() {
            if item.kind == .userPrompt {
                latestByWorkstream.removeValue(forKey: item.workstreamId)
                continue
            }
            guard item.kind.isActionable || item.kind == .todos || item.kind == .stop else {
                continue
            }
            latestByWorkstream[item.workstreamId] = (offset, item)
        }
        return latestByWorkstream.values
            .sorted { $0.offset > $1.offset }
            .map(\.item)
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

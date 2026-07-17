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
    private(set) var presentation = FeedPresentationSnapshot.empty
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
        storeInstallTask = Task { @MainActor [weak self, weak coordinator] in
            guard let coordinator else { return }
            self?.arm()
            for await _ in notificationCenter.notifications(
                named: FeedCoordinator.storeInstalledNotification,
                object: coordinator
            ) {
                guard !Task.isCancelled else { return }
                self?.arm()
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
            presentation = Self.makePresentation(items: store.items)
            hasMorePersistedItems = store.hasMorePersistedItems
            isLoadingOlderItems = store.isLoadingOlderItems
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.arm()
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

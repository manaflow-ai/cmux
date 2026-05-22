import CMUXWorkstream
import Foundation
import Observation
import SwiftUI

/// Bridges the `@Observable` WorkstreamStore to a panel-owned
/// observation snapshot so SwiftUI re-renders the Feed panel on every
/// relevant mutation.
@MainActor
@Observable
final class FeedPanelViewModel {
    private(set) var items: [WorkstreamItem] = []
    private(set) var agentGraphSnapshot: WorkstreamAgentGraphSnapshot = .empty
    private(set) var hasMorePersistedItems = false
    private(set) var isLoadingOlderItems = false
    @ObservationIgnored private var storeInstalledObserver: NSObjectProtocol?
    @ObservationIgnored private var graphBuildWorker = FeedAgentGraphBuildWorker()
    @ObservationIgnored private var graphBuildTask: Task<Void, Never>?
    @ObservationIgnored private var graphBuildSequence = 0
    @ObservationIgnored private var pendingGraphBuildRequest: AgentGraphBuildRequest?
    @ObservationIgnored private var activeGraphBuildSequence: Int?
    @ObservationIgnored private var isAgentTreeActive = false
    @ObservationIgnored private var loadOlderItemsTask: Task<Void, Never>?
    @ObservationIgnored private var loadOlderItemsSequence = 0

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
        graphBuildTask?.cancel()
        loadOlderItemsTask?.cancel()
        if let storeInstalledObserver {
            NotificationCenter.default.removeObserver(storeInstalledObserver)
        }
    }

    private func arm() {
        guard let store = FeedCoordinator.shared.store else { return }
        let storeSnapshot = withObservationTracking {
            FeedStoreObservationSnapshot(
                items: store.items,
                hasMorePersistedItems: store.hasMorePersistedItems,
                isLoadingOlderItems: store.isLoadingOlderItems
            )
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.arm()
            }
        }
        applyStoreObservationSnapshot(storeSnapshot)
    }

    private func applyStoreObservationSnapshot(_ snapshot: FeedStoreObservationSnapshot) {
        let previousItems = items
        items = snapshot.items
        if snapshot.items != previousItems {
            scheduleAgentGraphRebuildIfNeeded(from: snapshot.items)
        }
        hasMorePersistedItems = snapshot.hasMorePersistedItems
        isLoadingOlderItems = snapshot.isLoadingOlderItems
    }

    func loadOlderItems() {
        guard !isLoadingOlderItems,
              hasMorePersistedItems,
              loadOlderItemsTask == nil
        else { return }
        loadOlderItemsSequence &+= 1
        let sequence = loadOlderItemsSequence
        loadOlderItemsTask = Task { @MainActor [weak self, sequence] in
            guard let self, !Task.isCancelled else { return }
            defer {
                if self.loadOlderItemsSequence == sequence {
                    self.loadOlderItemsTask = nil
                }
            }
            await FeedCoordinator.shared.store?.loadOlderItems()
        }
    }

    func setAgentTreeActive(_ active: Bool) {
        guard isAgentTreeActive != active else { return }
        isAgentTreeActive = active
        if active {
            scheduleAgentGraphRebuildIfNeeded(from: items)
        } else {
            graphBuildSequence &+= 1
            graphBuildTask?.cancel()
            graphBuildTask = nil
            pendingGraphBuildRequest = nil
            activeGraphBuildSequence = nil
            agentGraphSnapshot = .empty
        }
    }

    private func scheduleAgentGraphRebuildIfNeeded(from currentItems: [WorkstreamItem]) {
        guard isAgentTreeActive else {
            graphBuildTask?.cancel()
            graphBuildTask = nil
            pendingGraphBuildRequest = nil
            activeGraphBuildSequence = nil
            if !agentGraphSnapshot.isEmpty {
                agentGraphSnapshot = .empty
            }
            return
        }

        graphBuildSequence &+= 1
        pendingGraphBuildRequest = AgentGraphBuildRequest(
            sequence: graphBuildSequence,
            items: currentItems
        )
        startNextAgentGraphBuildIfNeeded()
    }

    private func startNextAgentGraphBuildIfNeeded() {
        guard isAgentTreeActive,
              activeGraphBuildSequence == nil,
              let request = pendingGraphBuildRequest
        else { return }

        pendingGraphBuildRequest = nil
        activeGraphBuildSequence = request.sequence
        graphBuildTask = Task { [weak self, request] in
            guard let self, !Task.isCancelled else { return }
            guard let snapshot = await self.graphBuildWorker.snapshot(from: request.items) else {
                self.completeAgentGraphBuild(sequence: request.sequence, snapshot: nil)
                return
            }
            self.completeAgentGraphBuild(
                sequence: request.sequence,
                snapshot: Task.isCancelled ? nil : snapshot
            )
        }
    }

    private func completeAgentGraphBuild(
        sequence: Int,
        snapshot: WorkstreamAgentGraphSnapshot?
    ) {
        guard activeGraphBuildSequence == sequence else { return }
        activeGraphBuildSequence = nil
        graphBuildTask = nil

        if let snapshot,
           isAgentTreeActive,
           graphBuildSequence == sequence {
            agentGraphSnapshot = snapshot
        }

        startNextAgentGraphBuildIfNeeded()
    }
}

private struct AgentGraphBuildRequest {
    let sequence: Int
    let items: [WorkstreamItem]
}

private struct FeedStoreObservationSnapshot {
    let items: [WorkstreamItem]
    let hasMorePersistedItems: Bool
    let isLoadingOlderItems: Bool
}

private actor FeedAgentGraphBuildWorker {
    func snapshot(from items: [WorkstreamItem]) -> WorkstreamAgentGraphSnapshot? {
        guard !Task.isCancelled else { return nil }
        return WorkstreamAgentGraphBuilder.snapshot(from: items)
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

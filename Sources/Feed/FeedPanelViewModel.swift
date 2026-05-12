import CMUXWorkstream
import Foundation
import Observation
import SwiftUI

/// Bridges the `@Observable` WorkstreamStore to a Combine `@Published`
/// snapshot so SwiftUI reliably re-renders the Feed panel on every
/// mutation.
@MainActor
final class FeedPanelViewModel: ObservableObject {
    @Published private(set) var items: [WorkstreamItem] = []
    @Published private(set) var agentGraphSnapshot: WorkstreamAgentGraphSnapshot = .empty
    @Published private(set) var hasMorePersistedItems = false
    @Published private(set) var isLoadingOlderItems = false
    private var storeInstalledObserver: NSObjectProtocol?
    private let graphBuildWorker = FeedAgentGraphBuildWorker()
    private var graphBuildTask: Task<Void, Never>?
    private var graphBuildSequence = 0
    private var pendingGraphBuildRequest: AgentGraphBuildRequest?
    private var activeGraphBuildSequence: Int?
    private var isAgentTreeActive = false

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
        if let storeInstalledObserver {
            NotificationCenter.default.removeObserver(storeInstalledObserver)
        }
    }

    private func arm() {
        guard let store = FeedCoordinator.shared.store else { return }
        withObservationTracking {
            let currentItems = store.items
            items = currentItems
            scheduleAgentGraphRebuildIfNeeded(from: currentItems)
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

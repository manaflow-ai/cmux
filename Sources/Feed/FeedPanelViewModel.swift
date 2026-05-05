import CMUXWorkstream
import Foundation
import Observation
import SwiftUI

struct FeedActivityPaginationMetrics: Equatable {
    var viewportHeight: CGFloat = 0
    var contentHeight: CGFloat = 0

    var normalized: FeedActivityPaginationMetrics {
        FeedActivityPaginationMetrics(
            viewportHeight: ceil(max(0, viewportHeight)),
            contentHeight: ceil(max(0, contentHeight))
        )
    }
}

struct FeedActivityAutoPaginationState: Equatable {
    var isActive = false
    var automaticPagesRequested = 0
    var lastRequestedMetrics: FeedActivityPaginationMetrics?

    mutating func setActive(_ active: Bool) {
        guard isActive != active else { return }
        isActive = active
        automaticPagesRequested = 0
        lastRequestedMetrics = nil
    }

    mutating func recordRequest(metrics: FeedActivityPaginationMetrics) {
        automaticPagesRequested += 1
        lastRequestedMetrics = metrics
    }
}

enum FeedActivityAutoPaginationPolicy {
    static let preloadPadding: CGFloat = 80
    static let maxAutomaticPagesPerActivation = 3

    static func shouldRequestPage(
        metrics rawMetrics: FeedActivityPaginationMetrics,
        state: FeedActivityAutoPaginationState,
        hasMorePersistedItems: Bool,
        isLoadingOlderItems: Bool
    ) -> Bool {
        guard state.isActive,
              hasMorePersistedItems,
              !isLoadingOlderItems,
              state.automaticPagesRequested < maxAutomaticPagesPerActivation
        else { return false }

        let metrics = rawMetrics.normalized
        guard metrics.viewportHeight > 0, metrics.contentHeight > 0 else { return false }
        guard state.lastRequestedMetrics != metrics else { return false }
        return metrics.contentHeight <= metrics.viewportHeight + preloadPadding
    }
}

/// Bridges the `@Observable` WorkstreamStore to a UI-facing snapshot so
/// SwiftUI reliably re-renders the Feed panel on every mutation.
@MainActor
@Observable
final class FeedPanelViewModel {
    private(set) var items: [WorkstreamItem] = []
    private(set) var hasMorePersistedItems = false
    private(set) var isLoadingOlderItems = false

    @ObservationIgnored
    private var storeInstalledObserver: NSObjectProtocol?
    @ObservationIgnored
    private var activityPaginationState = FeedActivityAutoPaginationState()
    @ObservationIgnored
    private var activityPaginationMetrics = FeedActivityPaginationMetrics()
    @ObservationIgnored
    private var automaticLoadTask: Task<Void, Never>?

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
        automaticLoadTask?.cancel()
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
#if DEBUG
        recordActivityPaginationUITest(stage: "arm")
#endif
        requestAutomaticActivityPageIfNeeded()
    }

    nonisolated func loadOlderItems() {
        Task { @MainActor [weak self] in
            await self?.loadOlderItemsIfPossible()
        }
    }

    func setActivityAutoPaginationActive(_ active: Bool) {
        activityPaginationState.setActive(active)
        if !active {
            automaticLoadTask?.cancel()
            automaticLoadTask = nil
            return
        }
        requestAutomaticActivityPageIfNeeded()
    }

    func noteActivityViewportHeight(_ height: CGFloat) {
        let next = FeedActivityPaginationMetrics(
            viewportHeight: height,
            contentHeight: activityPaginationMetrics.contentHeight
        ).normalized
        guard next != activityPaginationMetrics else { return }
        activityPaginationMetrics = next
        requestAutomaticActivityPageIfNeeded()
    }

    func noteActivityContentHeight(_ height: CGFloat) {
        let next = FeedActivityPaginationMetrics(
            viewportHeight: activityPaginationMetrics.viewportHeight,
            contentHeight: height
        ).normalized
        guard next != activityPaginationMetrics else { return }
        activityPaginationMetrics = next
        requestAutomaticActivityPageIfNeeded()
    }

    func waitForActivityAutoPaginationIdleForTesting() async {
        while let task = automaticLoadTask {
            await task.value
        }
    }

    private func requestAutomaticActivityPageIfNeeded() {
        guard automaticLoadTask == nil else { return }
        let metrics = activityPaginationMetrics.normalized
        guard FeedActivityAutoPaginationPolicy.shouldRequestPage(
            metrics: metrics,
            state: activityPaginationState,
            hasMorePersistedItems: hasMorePersistedItems,
            isLoadingOlderItems: isLoadingOlderItems
        ) else { return }

        activityPaginationState.recordRequest(metrics: metrics)
#if DEBUG
        recordActivityPaginationUITest(stage: "auto.request")
#endif
        automaticLoadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.loadOlderItemsIfPossible()
            self.automaticLoadTask = nil
#if DEBUG
            self.recordActivityPaginationUITest(stage: "auto.idle")
#endif
            self.requestAutomaticActivityPageIfNeeded()
        }
    }

    private func loadOlderItemsIfPossible() async {
        guard !isLoadingOlderItems, hasMorePersistedItems else { return }
        await FeedCoordinator.shared.store?.loadOlderItems()
        arm()
    }

#if DEBUG
    private func recordActivityPaginationUITest(stage: String) {
        _ = CmuxUITestCapture.mutateJSONObjectIfConfigured(
            envKey: "CMUX_UI_TEST_FEED_ACTIVITY_PAGINATION_PATH"
        ) { payload in
            let metrics = activityPaginationMetrics.normalized
            payload["stage"] = stage
            payload["itemsCount"] = "\(items.count)"
            payload["hasMorePersistedItems"] = hasMorePersistedItems ? "1" : "0"
            payload["isLoadingOlderItems"] = isLoadingOlderItems ? "1" : "0"
            payload["activityAutoPaginationActive"] = activityPaginationState.isActive ? "1" : "0"
            payload["activityAutoPagesRequested"] = "\(activityPaginationState.automaticPagesRequested)"
            payload["activityViewportHeight"] = "\(Int(metrics.viewportHeight.rounded()))"
            payload["activityContentHeight"] = "\(Int(metrics.contentHeight.rounded()))"
        }
    }
#endif
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
        .accessibilityIdentifier("FeedHistoryLoadMoreButton")
    }

    private var label: String {
        if isLoading {
            return String(localized: "feed.history.loadingOlder", defaultValue: "Loading older activity...")
        }
        return String(localized: "feed.history.loadOlder", defaultValue: "Load older activity")
    }

}

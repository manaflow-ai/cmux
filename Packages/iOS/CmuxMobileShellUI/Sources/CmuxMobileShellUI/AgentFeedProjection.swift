#if os(iOS)
import CmuxMobileShellModel
import Foundation
import Observation

struct AgentFeedProjectionOutput: Sendable {
    let rows: [AgentFeedRowModel]
    let needsInputCount: Int
}

private struct AgentFeedProjectionWorkerOutput: Sendable {
    let projection: AgentFeedProjectionOutput
    let rowModelCache: AgentFeedRowModelCache
}

/// Maintains the rows mounted by the Agent Feed outside SwiftUI list-body
/// evaluation. Snapshot updates arrive as full retained histories, so both
/// row preparation and filtering run in a cancellable background rebuild.
@MainActor
@Observable
final class AgentFeedProjection {
    var filter: AgentFeedFilter = .all {
        didSet {
            guard filter != oldValue else { return }
            scheduleRebuild()
        }
    }

    var searchText = "" {
        didSet {
            guard searchText != oldValue else { return }
            scheduleRebuild(
                debounce: searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? nil
                    : .milliseconds(200)
            )
        }
    }

    private(set) var rows: [AgentFeedRowModel]
    private(set) var needsInputCount: Int

    @ObservationIgnored private var sourceItems: [MobileAgentFeedItem]
    @ObservationIgnored private var rowModelCache: AgentFeedRowModelCache
    @ObservationIgnored private var requestedItemsRevision: AgentFeedItemsRevision
    private(set) var publishedSourceRevision: UInt64
    private(set) var publishedScopeRevision: AgentFeedScopeRevision?
    @ObservationIgnored private var sourceRevision = 0
    @ObservationIgnored private var rebuildRevision = 0
    @ObservationIgnored private var rebuildTask: Task<Void, Never>?

    init(
        items: [MobileAgentFeedItem],
        itemsRevision: AgentFeedItemsRevision = AgentFeedItemsRevision(sourceRevision: 0),
        filter: AgentFeedFilter = .all,
        searchText: String = ""
    ) {
        self.filter = filter
        self.searchText = searchText
        sourceItems = items
        requestedItemsRevision = itemsRevision
        publishedSourceRevision = itemsRevision.sourceRevision
        publishedScopeRevision = itemsRevision.scopeRevision

        var rowModelCache = AgentFeedRowModelCache()
        let preparedRows = rowModelCache.update(items: items)
        let output = agentFeedProjectionBuild(
            preparedRows: preparedRows,
            filter: filter,
            searchText: searchText
        )
        self.rowModelCache = rowModelCache
        rows = output.rows
        needsInputCount = output.needsInputCount
    }

    func update(
        items: [MobileAgentFeedItem],
        itemsRevision: AgentFeedItemsRevision = AgentFeedItemsRevision(sourceRevision: 0)
    ) {
        guard sourceItems != items || requestedItemsRevision != itemsRevision else { return }
        sourceItems = items
        requestedItemsRevision = itemsRevision
        sourceRevision &+= 1
        scheduleRebuild()
    }

    func rows(for itemsRevision: AgentFeedItemsRevision) -> [AgentFeedRowModel] {
        guard publishedScopeRevision == itemsRevision.scopeRevision else { return [] }
        return rows
    }

    func needsInputCount(for itemsRevision: AgentFeedItemsRevision) -> Int {
        guard publishedScopeRevision == itemsRevision.scopeRevision else { return 0 }
        return needsInputCount
    }

    func waitForPendingRebuild() async {
        await rebuildTask?.value
    }

    private func scheduleRebuild(debounce: Duration? = nil) {
        rebuildRevision &+= 1
        let requestedRebuildRevision = rebuildRevision
        let requestedSourceRevision = sourceRevision
        let requestedItems = sourceItems
        let requestedItemsRevision = requestedItemsRevision
        let requestedFilter = filter
        let requestedSearchText = searchText
        let requestedRowModelCache = rowModelCache

        rebuildTask?.cancel()
        rebuildTask = Task { [weak self] in
            if let debounce {
                do {
                    try await ContinuousClock().sleep(for: debounce)
                } catch {
                    return
                }
            }
            guard !Task.isCancelled else { return }

            let worker = Task.detached(priority: .utility) {
                agentFeedProjectionBuild(
                    items: requestedItems,
                    rowModelCache: requestedRowModelCache,
                    filter: requestedFilter,
                    searchText: requestedSearchText
                )
            }
            let output = await withTaskCancellationHandler(
                operation: { await worker.value },
                onCancel: { worker.cancel() }
            )
            guard
                !Task.isCancelled,
                let output,
                let self,
                self.rebuildRevision == requestedRebuildRevision,
                self.sourceRevision == requestedSourceRevision
            else {
                return
            }

            self.rowModelCache = output.rowModelCache
            self.rows = output.projection.rows
            self.needsInputCount = output.projection.needsInputCount
            self.publishedSourceRevision = requestedItemsRevision.sourceRevision
            self.publishedScopeRevision = requestedItemsRevision.scopeRevision
        }
    }
}

private nonisolated func agentFeedProjectionBuild(
    items: [MobileAgentFeedItem],
    rowModelCache: AgentFeedRowModelCache,
    filter: AgentFeedFilter,
    searchText: String
) -> AgentFeedProjectionWorkerOutput? {
    var rowModelCache = rowModelCache
    guard let preparedRows = rowModelCache.update(
        items: items,
        stopIfCancelled: { Task.isCancelled }
    ) else {
        return nil
    }

    let projection = agentFeedProjectionBuild(
        preparedRows: preparedRows,
        filter: filter,
        searchText: searchText
    )
    guard !Task.isCancelled else { return nil }
    return AgentFeedProjectionWorkerOutput(
        projection: projection,
        rowModelCache: rowModelCache
    )
}

private nonisolated func agentFeedProjectionBuild(
    preparedRows: [AgentFeedRowModel],
    filter: AgentFeedFilter,
    searchText: String
) -> AgentFeedProjectionOutput {
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    var notable: [AgentFeedRowModel] = []
    notable.reserveCapacity(preparedRows.count)

    for model in preparedRows {
        let item = model.item
        // Notification history belongs to the Notifications tab. Keep this
        // client-side guard for snapshots produced by older Macs.
        guard item.source.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare("notification") != .orderedSame else {
            continue
        }
        guard query.isEmpty || item.matchesFeedSearch(query) else { continue }
        switch item.kind {
        case .toolUse, .userPrompt:
            continue
        case .toolResult:
            guard item.toolResultIsError else { continue }
        case .permissionRequest, .exitPlan, .question,
             .assistantMessage, .stop, .todos, .unsupported:
            break
        }
        guard model.hasVisibleContent else { continue }
        notable.append(model)
    }

    let visibleRows: [AgentFeedRowModel]
    switch filter {
    case .all:
        visibleRows = notable
    case .needsInput:
        visibleRows = notable.filter(\.item.effectiveNeedsInput)
    }
    let needsInputCount = preparedRows.lazy
        .filter { model in
            model.item.source.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare("notification") != .orderedSame
        }
        .filter(\.item.effectiveNeedsInput)
        .count
    return AgentFeedProjectionOutput(
        rows: visibleRows,
        needsInputCount: needsInputCount
    )
}
#endif

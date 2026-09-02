import CmuxControlSocket
import CmuxWorkspaces
import Foundation
import Observation

/// Main-actor projection and action owner for the cross-workspace task queue.
/// The model never stores task truth: every refresh re-reads live
/// `WorkspaceTodoState` through the shared control seam.
@MainActor
@Observable
final class WorkspaceTaskQueueModel {
    enum StatusFilter: String, CaseIterable, Identifiable {
        case all
        case pending
        case inProgress = "in-progress"
        case completed

        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: String(localized: "taskQueue.filter.status.all", defaultValue: "All statuses")
            case .pending: String(localized: "taskQueue.filter.status.pending", defaultValue: "Pending")
            case .inProgress: String(localized: "taskQueue.filter.status.inProgress", defaultValue: "In progress")
            case .completed: String(localized: "taskQueue.filter.status.completed", defaultValue: "Completed")
            }
        }
    }

    enum SortKey: String, CaseIterable, Identifiable {
        case activity
        case status
        case workspace

        var id: String { rawValue }
        var title: String {
            switch self {
            case .activity: String(localized: "taskQueue.sort.activity", defaultValue: "Last activity")
            case .status: String(localized: "taskQueue.sort.status", defaultValue: "Status")
            case .workspace: String(localized: "taskQueue.sort.workspace", defaultValue: "Workspace")
            }
        }
    }

    private(set) var rows: [ControlWorkspaceTaskQueueItem] = []
    private(set) var workspaceOptions: [(id: UUID, title: String)] = []
    private(set) var isRefreshing = false
    private(set) var errorMessage: String?
    /// Immutable source snapshot used to populate the cached presentation
    /// orders; cache mutation must not invalidate the SwiftUI view by itself.
    @ObservationIgnored private var sourceRows: [ControlWorkspaceTaskQueueItem] = []
    @ObservationIgnored private var sortedRowsByKey: [SortKey: [ControlWorkspaceTaskQueueItem]] = [:]
    @ObservationIgnored private var scheduledRefresh: Task<Void, Never>?
    @ObservationIgnored private var refreshRequested = false
    @ObservationIgnored private var refreshGeneration: UInt64 = 0
    var statusFilter: StatusFilter = .all { didSet { refresh() } }
    var workspaceFilter: UUID? { didSet { rows = displayedRows() } }
    var sortKey: SortKey = .activity { didSet { rows = displayedRows() } }
    var selectedRowID: UUID?

    init() {
        refresh()
    }

    func refresh() {
        scheduledRefresh?.cancel()
        scheduledRefresh = nil
        refreshRequested = false
        performRefresh()
    }

    private func performRefresh() {
        isRefreshing = true
        defer { isRefreshing = false }
        let status = statusFilter == .all ? nil : statusFilter.rawValue
        switch TerminalController.shared.controlWorkspaceTaskQueueList(
            statusRaw: status,
            workspaceID: nil,
            windowID: nil
        ) {
        case .tabManagerUnavailable:
            sourceRows = []
            sortedRowsByKey.removeAll(keepingCapacity: true)
            rows = []
            workspaceOptions = []
            errorMessage = String(localized: "taskQueue.error.unavailable", defaultValue: "Task queue is unavailable while cmux is starting.")
        case .resolved(let items):
            sourceRows = items
            sortedRowsByKey.removeAll(keepingCapacity: true)
            rebuildWorkspaceOptions(from: items)
            rows = displayedRows()
            errorMessage = nil
        }
    }

    /// Coalesces a burst of checklist notifications into one main-actor read.
    /// Task-yield is a scheduling boundary, not a time-based retry or poll.
    func scheduleRefresh() {
        refreshGeneration &+= 1
        refreshRequested = true
        guard scheduledRefresh == nil else { return }
        scheduledRefresh = Task { @MainActor [weak self] in
            guard let self else { return }
            await Task.yield()
            guard !Task.isCancelled else { return }
            let generation = self.refreshGeneration
            self.refreshRequested = false
            self.scheduledRefresh = nil
            self.performRefresh()
            guard !Task.isCancelled,
                  self.refreshRequested,
                  self.refreshGeneration != generation,
                  self.scheduledRefresh == nil else { return }
            self.scheduleRefresh()
        }
    }

    func dispatch(_ row: ControlWorkspaceTaskQueueItem) {
        switch TerminalController.shared.controlWorkspaceTaskQueueDispatch(
            itemID: row.id,
            routing: ControlRoutingSelectors(
                hasWindowIDParam: false,
                windowID: nil,
                groupID: nil,
                workspaceID: nil,
                surfaceID: nil,
                paneID: nil
            )
        ) {
        case .created:
            refresh()
        case .notDispatchable:
            errorMessage = String(localized: "taskQueue.error.noTarget", defaultValue: "Add a working directory and agent command before dispatching this task.")
        case .notFound:
            errorMessage = String(localized: "taskQueue.error.notFound", defaultValue: "That task is no longer available.")
        case .tabManagerUnavailable:
            errorMessage = String(localized: "taskQueue.error.unavailable", defaultValue: "Task queue is unavailable while cmux is starting.")
        }
    }

    func reveal(_ row: ControlWorkspaceTaskQueueItem) {
        switch TerminalController.shared.controlWorkspaceTaskQueueReveal(itemID: row.id) {
        case .revealed:
            selectedRowID = row.id
        case .notFound:
            errorMessage = String(localized: "taskQueue.error.notFound", defaultValue: "That task is no longer available.")
        case .tabManagerUnavailable:
            errorMessage = String(localized: "taskQueue.error.unavailable", defaultValue: "Task queue is unavailable while cmux is starting.")
        }
    }

    private func rebuildWorkspaceOptions(from rows: [ControlWorkspaceTaskQueueItem]) {
        let values = rows.reduce(into: [UUID: String]()) { result, row in
            result[row.workspaceID] = row.workspaceTitle
        }
        workspaceOptions = values.keys.sorted { lhs, rhs in
            let leftTitle = values[lhs, default: ""]
            let rightTitle = values[rhs, default: ""]
            return leftTitle == rightTitle ? lhs.uuidString < rhs.uuidString : leftTitle < rightTitle
        }.map { ($0, values[$0, default: ""]) }
    }

    private func sortedRows(for key: SortKey) -> [ControlWorkspaceTaskQueueItem] {
        if let cached = sortedRowsByKey[key] {
            return cached
        }
        var sorted = sourceRows
        sorted.sort { lhs, rhs in
            switch key {
            case .activity:
                if lhs.lastActivityAt != rhs.lastActivityAt {
                    return (lhs.lastActivityAt ?? .distantPast) > (rhs.lastActivityAt ?? .distantPast)
                }
            case .status:
                if lhs.state != rhs.state { return stateRank(lhs.state) < stateRank(rhs.state) }
            case .workspace:
                if lhs.workspaceTitle != rhs.workspaceTitle { return lhs.workspaceTitle < rhs.workspaceTitle }
            }
            if lhs.workspaceTitle != rhs.workspaceTitle { return lhs.workspaceTitle < rhs.workspaceTitle }
            if lhs.state != rhs.state { return stateRank(lhs.state) < stateRank(rhs.state) }
            let textOrder = lhs.text.localizedStandardCompare(rhs.text)
            if textOrder != .orderedSame { return textOrder == .orderedAscending }
            return lhs.id.uuidString < rhs.id.uuidString
        }
        sortedRowsByKey[key] = sorted
        return sorted
    }

    private func displayedRows() -> [ControlWorkspaceTaskQueueItem] {
        let sorted = sortedRows(for: sortKey)
        guard let workspaceFilter else { return sorted }
        return sorted.filter { $0.workspaceID == workspaceFilter }
    }

    private func stateRank(_ state: String) -> Int {
        switch state {
        case "in-progress": 0
        case "pending": 1
        case "completed": 2
        default: 3
        }
    }

    deinit {
        scheduledRefresh?.cancel()
    }
}

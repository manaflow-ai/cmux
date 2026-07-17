import CmuxFoundation
import Foundation
import Observation

/// Main-actor owner for one visible repository section's transient worktree UI state.
@MainActor
@Observable
final class WorktreeSidebarModel {
    enum ListingPhase: Equatable {
        case idle
        case loading
        case loaded
        case failed
    }

    enum OperationPhase: Equatable {
        case idle
        case creating
        case inspecting(String)
        case removing(String)
    }

    private enum LifecyclePhase {
        case stopped
        case running
    }

    private enum RefreshState {
        case idle
        case running(needsRerun: Bool)
    }

    let projectRootPath: String
    private(set) var rows: [WorktreeSidebarRow] = []
    private(set) var listingPhase: ListingPhase = .idle
    private(set) var operationPhase: OperationPhase = .idle
    private(set) var listingErrorDetails: String?

    @ObservationIgnored private let git: any WorktreeSidebarGitOperating
    @ObservationIgnored private let dialogs: any WorktreeSidebarDialogPresenting
    @ObservationIgnored private let workspaces: WorktreeSidebarWorkspaceController
    @ObservationIgnored private var lifecyclePhase: LifecyclePhase = .stopped
    @ObservationIgnored private var refreshState: RefreshState = .idle
    @ObservationIgnored private var worktrees: [WorktreeSidebarWorktree] = []
    @ObservationIgnored private var worktreeByPath: [String: WorktreeSidebarWorktree] = [:]
    @ObservationIgnored private var worktreePaths: [String] = []
    @ObservationIgnored private var statusByPath: [String: WorktreeSidebarStatus] = [:]
    @ObservationIgnored private var rowIndexByPath: [String: Int] = [:]
    @ObservationIgnored private var minimumListingRequestIDByRemovedPath: [String: UInt64] = [:]
    @ObservationIgnored private var visiblePaths: Set<String> = []
    @ObservationIgnored private var staleStatusRefreshPaths: Set<String> = []
    @ObservationIgnored private var statusScheduler: WorktreeSidebarStatusScheduler!
    @ObservationIgnored private var listingRequestID: UInt64 = 0
    @ObservationIgnored private var listingTask: Task<Void, Never>?
    @ObservationIgnored private var listingWatcherInstallTask: Task<Void, Never>?
    @ObservationIgnored private let listingWatcher = WorktreeSidebarListingWatcher()
    @ObservationIgnored private var statusWatcherInstallTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var statusWatchPlans: [String: WorktreeSidebarStatusWatchPlan] = [:]
    @ObservationIgnored private var statusRecursiveWatchers: [String: RecursivePathWatcher] = [:]
    @ObservationIgnored private var statusRecursiveWatcherTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var statusShallowWatchers: [String: [FileWatcher]] = [:]
    @ObservationIgnored private var statusShallowWatcherTasks: [String: [Task<Void, Never>]] = [:]

    init(
        projectRootPath: String,
        git: (any WorktreeSidebarGitOperating)? = nil,
        dialogs: (any WorktreeSidebarDialogPresenting)? = nil,
        workspaces: WorktreeSidebarWorkspaceController,
        statusDebounceDuration: Duration = .milliseconds(750)
    ) {
        self.projectRootPath = projectRootPath
        self.git = git ?? WorktreeSidebarGitService()
        self.dialogs = dialogs ?? WorktreeSidebarDialogPresenter()
        self.workspaces = workspaces
        let git = self.git
        let root = projectRootPath
        self.statusScheduler = WorktreeSidebarStatusScheduler(
            delay: statusDebounceDuration,
            probe: { path in
                do {
                    return try await git.isDirty(
                        projectRootPath: root,
                        worktreePath: path
                    ) ? .success(.dirty) : .success(.clean)
                } catch {
                    return .failure
                }
            },
            completion: { [weak self] path, result in
                self?.completeStatusProbe(path: path, result: result)
            }
        )
    }

    var isRefreshing: Bool { listingPhase == .loading }
    var isBusy: Bool { operationPhase != .idle }
    var isInitialLoading: Bool { rows.isEmpty && listingPhase == .loading }

    func start() {
        guard lifecyclePhase == .stopped else { return }
        lifecyclePhase = .running
        statusScheduler.start()
        refresh()
        reconcileListingWatcher()
    }

    func stop() {
        lifecyclePhase = .stopped
        statusScheduler.stop()
        listingRequestID &+= 1
        listingTask?.cancel()
        listingTask = nil
        listingWatcherInstallTask?.cancel()
        listingWatcherInstallTask = nil
        listingWatcher.stop()
        for path in Array(visiblePaths) {
            stopStatusTracking(path: path)
        }
        visiblePaths.removeAll()
        refreshState = .idle
    }

    func refreshAll() {
        refresh()
        for path in visiblePaths {
            scheduleStatusRefresh(path: path)
        }
    }

    func createWorktree() {
        guard operationPhase == .idle else { return }
        if let didExecute = workspaces.executeConfiguredCreateActionIfAvailable(
            projectRootPath: projectRootPath
        ) {
            if didExecute { refreshAll() }
            return
        }
        let projectName = URL(fileURLWithPath: projectRootPath, isDirectory: true).lastPathComponent
        guard let userInput = dialogs.promptForBranchName(projectName: projectName) else { return }

        operationPhase = .creating
        Task { [weak self] in
            guard let self else { return }
            do {
                let creation = try await git.createWorktree(
                    projectRootPath: projectRootPath,
                    userInput: userInput
                )
                workspaces.openTerminal(WorktreeSidebarWorkspaceRequest(
                    worktreePath: creation.worktreePath,
                    title: creation.branchName
                ))
            } catch let error as WorktreeSidebarGitError {
                if case .submoduleInitializationFailed(let creation, _) = error {
                    workspaces.openTerminal(WorktreeSidebarWorkspaceRequest(
                        worktreePath: creation.worktreePath,
                        title: creation.branchName
                    ))
                }
                dialogs.presentError(error)
            } catch {
                dialogs.presentError(error)
            }
            operationPhase = .idle
            refreshAll()
        }
    }

    func openTerminal(for row: WorktreeSidebarRow) {
        guard !row.worktree.isPrunable,
              operationPhase != .removing(row.id),
              minimumListingRequestIDByRemovedPath[row.worktree.path] == nil,
              worktreeByPath[row.worktree.path]?.id == row.worktree.id else {
            return
        }
        if workspaces.executeConfiguredOpenActionIfAvailable(
            projectRootPath: projectRootPath,
            worktreePath: row.worktree.path
        ) != nil {
            return
        }
        workspaces.openTerminal(WorktreeSidebarWorkspaceRequest(
            worktreePath: row.worktree.path,
            title: row.worktree.name
        ))
    }

    func requestDeletion(for row: WorktreeSidebarRow) {
        guard operationPhase == .idle,
              !row.worktree.isMain,
              !row.worktree.isLocked else {
            return
        }
        operationPhase = .inspecting(row.id)
        Task { [weak self] in
            guard let self else { return }
            do {
                let inspection = try await git.inspectDeletion(
                    projectRootPath: projectRootPath,
                    worktreePath: row.worktree.path
                )
                guard dialogs.confirmDeletion(inspection, force: false) else {
                    operationPhase = .idle
                    return
                }
                let force = inspection.requiresForceRemoval
                if force, !dialogs.confirmDeletion(inspection, force: true) {
                    operationPhase = .idle
                    return
                }

                let closePlan = await workspaces.closePlan(
                    worktreePath: inspection.worktree.path,
                    fallbackDirectory: projectRootPath
                )
                operationPhase = .removing(row.id)
                let result = try await git.removeWorktree(
                    projectRootPath: projectRootPath,
                    expected: inspection,
                    force: force
                )
                minimumListingRequestIDByRemovedPath[inspection.worktree.path] = listingRequestID &+ 1
                workspaces.apply(closePlan)
                if case .preserved(let name, let reason) = result.branch {
                    dialogs.presentPreservedBranch(name: name, reason: reason)
                }
            } catch {
                dialogs.presentError(error)
            }
            operationPhase = .idle
            refreshAll()
        }
    }

    func rowBecameVisible(_ row: WorktreeSidebarRow) {
        let path = row.worktree.path
        guard visiblePaths.insert(path).inserted else { return }
        guard !row.worktree.isPrunable else { return }
        scheduleStatusRefresh(path: path)
        reconcileStatusWatcher(path: path)
    }

    func rowBecameHidden(_ row: WorktreeSidebarRow) {
        visiblePaths.remove(row.worktree.path)
        stopStatusTracking(path: row.worktree.path)
    }

    private func refresh() {
        guard lifecyclePhase == .running else { return }
        switch refreshState {
        case .idle:
            refreshState = .running(needsRerun: false)
        case .running:
            refreshState = .running(needsRerun: true)
            return
        }

        listingPhase = .loading
        listingRequestID &+= 1
        let requestID = listingRequestID
        listingTask = Task { [weak self] in
            guard let self else { return }
            do {
                let worktrees = try await git.listWorktrees(projectRootPath: projectRootPath)
                guard !Task.isCancelled,
                      lifecyclePhase == .running,
                      listingRequestID == requestID else {
                    return
                }
                apply(worktrees: worktrees, requestID: requestID)
                listingErrorDetails = nil
                listingPhase = .loaded
            } catch {
                guard !Task.isCancelled,
                      lifecyclePhase == .running,
                      listingRequestID == requestID else {
                    return
                }
                listingErrorDetails = Self.details(for: error)
                listingPhase = .failed
            }
            listingTask = nil
            let needsRerun: Bool
            switch refreshState {
            case .idle:
                needsRerun = false
            case .running(let pending):
                needsRerun = pending
            }
            refreshState = .idle
            if needsRerun { refresh() }
        }
    }

    private func apply(worktrees: [WorktreeSidebarWorktree], requestID: UInt64) {
        self.worktrees = worktrees
        worktreeByPath = Dictionary(uniqueKeysWithValues: worktrees.map { ($0.path, $0) })
        worktreePaths = worktrees.map(\.path)
        let validPaths = Set(worktrees.map(\.path))
        minimumListingRequestIDByRemovedPath = minimumListingRequestIDByRemovedPath.filter {
            $0.value > requestID || validPaths.contains($0.key)
        }
        for path in visiblePaths.subtracting(validPaths) {
            stopStatusTracking(path: path)
        }
        statusByPath = statusByPath.filter { validPaths.contains($0.key) }
        staleStatusRefreshPaths.formIntersection(validPaths)
        visiblePaths.formIntersection(validPaths)
        for worktree in worktrees where worktree.isPrunable {
            statusByPath[worktree.path] = .unavailable
            staleStatusRefreshPaths.remove(worktree.path)
            stopStatusTracking(path: worktree.path)
        }
        rebuildRows()
        for path in visiblePaths {
            scheduleStatusRefresh(path: path)
            reconcileStatusWatcher(path: path)
        }
        reconcileListingWatcher()
    }

    private func rebuildRows() {
        rows = worktrees.map { worktree in
            WorktreeSidebarRow(
                worktree: worktree,
                status: statusByPath[worktree.path] ?? .unknown
            )
        }
        rowIndexByPath = Dictionary(uniqueKeysWithValues: rows.indices.map {
            (rows[$0].worktree.path, $0)
        })
    }

    private func updateStatus(_ status: WorktreeSidebarStatus, path: String) {
        guard statusByPath[path] != status else { return }
        statusByPath[path] = status
        guard let index = rowIndexByPath[path] else { return }
        let current = rows[index]
        rows[index] = WorktreeSidebarRow(worktree: current.worktree, status: status)
    }

    private func scheduleStatusRefresh(path: String) {
        guard lifecyclePhase == .running,
              visiblePaths.contains(path),
              worktreeByPath[path]?.isPrunable == false else {
            return
        }
        guard statusScheduler.enqueue(path: path) else { return }
        if statusByPath[path] == nil || statusByPath[path] == .unknown {
            updateStatus(.loading, path: path)
        }
    }

    private func completeStatusProbe(
        path: String,
        result: WorktreeSidebarStatusScheduler.ProbeResult
    ) {
        guard lifecyclePhase == .running,
              visiblePaths.contains(path),
              worktreeByPath[path]?.isPrunable == false else {
            return
        }
        switch result {
        case .success(let status):
            staleStatusRefreshPaths.remove(path)
            updateStatus(status, path: path)
        case .failure:
            requestListingRefreshAfterStatusFailure(path: path)
        }
    }

    private func reconcileListingWatcher() {
        guard lifecyclePhase == .running else { return }
        listingWatcherInstallTask?.cancel()
        listingWatcherInstallTask = Task { [weak self] in
            guard let self else { return }
            let plan = await git.listingWatchPlan(projectRootPath: projectRootPath)
            guard !Task.isCancelled, lifecyclePhase == .running else { return }
            await listingWatcher.reconcile(plan: plan) { [weak self] in
                self?.refresh()
            }
        }
    }

    private func reconcileStatusWatcher(path: String) {
        guard lifecyclePhase == .running,
              visiblePaths.contains(path),
              worktreeByPath[path]?.isPrunable == false else {
            return
        }
        statusWatcherInstallTasks[path]?.cancel()
        let excludedPaths = worktreePaths
        statusWatcherInstallTasks[path] = Task { [weak self] in
            guard let self else { return }
            let plan = await git.statusWatchPlan(
                worktreePath: path,
                excludingWorktreePaths: excludedPaths
            )
            guard !Task.isCancelled,
                  lifecyclePhase == .running,
                  visiblePaths.contains(path) else {
                return
            }
            if statusWatchPlans[path] == plan { return }
            statusWatchPlans.removeValue(forKey: path)
            statusRecursiveWatcherTasks.removeValue(forKey: path)?.cancel()
            statusShallowWatcherTasks.removeValue(forKey: path)?.forEach { $0.cancel() }
            let previousRecursiveWatcher = statusRecursiveWatchers.removeValue(forKey: path)
            let previousShallowWatchers = statusShallowWatchers.removeValue(forKey: path) ?? []
            if let previousRecursiveWatcher { await previousRecursiveWatcher.stop() }
            for watcher in previousShallowWatchers { await watcher.stop() }
            guard !Task.isCancelled,
                  lifecyclePhase == .running,
                  visiblePaths.contains(path) else {
                return
            }
            statusWatchPlans[path] = plan
            if let watcher = RecursivePathWatcher(paths: plan.recursivePaths) {
                statusRecursiveWatchers[path] = watcher
                statusRecursiveWatcherTasks[path] = Task { @MainActor [weak self] in
                    for await _ in watcher.events {
                        guard let self else { break }
                        handleStatusWatchEvent(path: path)
                    }
                }
            }
            let shallowWatchers = plan.shallowPaths.map {
                FileWatcher(path: $0, throttle: .milliseconds(250))
            }
            statusShallowWatchers[path] = shallowWatchers
            statusShallowWatcherTasks[path] = shallowWatchers.map { watcher in
                Task { @MainActor [weak self] in
                    for await _ in watcher.events {
                        guard let self else { break }
                        handleStatusWatchEvent(path: path)
                        reconcileStatusWatcher(path: path)
                    }
                }
            }
        }
    }

    private func handleStatusWatchEvent(path: String) {
        guard let worktree = worktreeByPath[path] else {
            refresh()
            return
        }
        guard !worktree.isPrunable else { return }
        scheduleStatusRefresh(path: path)
    }

    private func stopStatusTracking(path: String) {
        statusScheduler.remove(path: path)
        statusWatcherInstallTasks.removeValue(forKey: path)?.cancel()
        statusWatchPlans.removeValue(forKey: path)
        statusRecursiveWatcherTasks.removeValue(forKey: path)?.cancel()
        statusShallowWatcherTasks.removeValue(forKey: path)?.forEach { $0.cancel() }
        if let watcher = statusRecursiveWatchers.removeValue(forKey: path) {
            Task { await watcher.stop() }
        }
        let shallowWatchers = statusShallowWatchers.removeValue(forKey: path) ?? []
        if !shallowWatchers.isEmpty {
            Task {
                for watcher in shallowWatchers { await watcher.stop() }
            }
        }
    }

    private func requestListingRefreshAfterStatusFailure(path: String) {
        statusScheduler.remove(path: path)
        updateStatus(.unavailable, path: path)
        guard staleStatusRefreshPaths.insert(path).inserted else { return }
        refresh()
    }

    private static func details(for error: Error) -> String {
        guard let gitError = error as? WorktreeSidebarGitError else { return "" }
        if case .commandFailed(_, let details) = gitError {
            return String(details.prefix(2_000))
        }
        return ""
    }
}

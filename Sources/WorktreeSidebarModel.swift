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
    @ObservationIgnored private let dialogs: WorktreeSidebarDialogPresenter
    @ObservationIgnored private let workspaces: WorktreeSidebarWorkspaceController
    @ObservationIgnored private var lifecyclePhase: LifecyclePhase = .stopped
    @ObservationIgnored private var refreshState: RefreshState = .idle
    @ObservationIgnored private var worktrees: [WorktreeSidebarWorktree] = []
    @ObservationIgnored private var statusByPath: [String: WorktreeSidebarStatus] = [:]
    @ObservationIgnored private var visiblePaths: Set<String> = []
    @ObservationIgnored private var staleStatusRefreshPaths: Set<String> = []
    @ObservationIgnored private var statusScheduler: WorktreeSidebarStatusScheduler!
    @ObservationIgnored private var listingRequestID: UInt64 = 0
    @ObservationIgnored private var listingTask: Task<Void, Never>?
    @ObservationIgnored private var listingWatcherInstallTask: Task<Void, Never>?
    @ObservationIgnored private var listingWatcher: RecursivePathWatcher?
    @ObservationIgnored private var listingWatcherTask: Task<Void, Never>?
    @ObservationIgnored private var statusWatcherInstallTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var statusWatchers: [String: RecursivePathWatcher] = [:]
    @ObservationIgnored private var statusWatcherTasks: [String: Task<Void, Never>] = [:]

    init(
        projectRootPath: String,
        git: (any WorktreeSidebarGitOperating)? = nil,
        dialogs: WorktreeSidebarDialogPresenter? = nil,
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
        listingWatcherTask?.cancel()
        listingWatcherTask = nil
        if let listingWatcher {
            Task { await listingWatcher.stop() }
        }
        listingWatcher = nil
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
              operationPhase != .removing(row.id) else {
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

                operationPhase = .removing(row.id)
                let result = try await git.removeWorktree(
                    projectRootPath: projectRootPath,
                    expected: inspection,
                    force: force
                )
                workspaces.apply(workspaces.closePlan(
                    worktreePath: inspection.worktree.path,
                    fallbackDirectory: projectRootPath
                ))
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
        guard prepareStatusProbe(for: row.worktree) else { return }
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
                apply(worktrees: worktrees)
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

    private func apply(worktrees: [WorktreeSidebarWorktree]) {
        self.worktrees = worktrees
        let validPaths = Set(worktrees.map(\.path))
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
    }

    private func scheduleStatusRefresh(path: String) {
        guard lifecyclePhase == .running,
              visiblePaths.contains(path),
              let worktree = worktrees.first(where: { $0.path == path && !$0.isPrunable }),
              prepareStatusProbe(for: worktree) else {
            return
        }
        guard statusScheduler.enqueue(path: path) else { return }
        if statusByPath[path] == nil || statusByPath[path] == .unknown {
            statusByPath[path] = .loading
            rebuildRows()
        }
    }

    private func completeStatusProbe(
        path: String,
        result: WorktreeSidebarStatusScheduler.ProbeResult
    ) {
        guard lifecyclePhase == .running,
              visiblePaths.contains(path),
              let worktree = worktrees.first(where: { $0.path == path && !$0.isPrunable }) else {
            return
        }
        switch result {
        case .success(let status):
            statusByPath[path] = status
            rebuildRows()
        case .failure:
            if requiresListingRefresh(for: worktree) {
                requestListingRefreshForStaleWorktree(path: path)
            } else {
                statusByPath[path] = .unavailable
                rebuildRows()
            }
        }
    }

    private func reconcileListingWatcher() {
        guard lifecyclePhase == .running else { return }
        listingWatcherInstallTask?.cancel()
        listingWatcherInstallTask = Task { [weak self] in
            guard let self else { return }
            let paths = await git.listingWatchPaths(projectRootPath: projectRootPath)
            guard !Task.isCancelled, lifecyclePhase == .running else { return }
            if listingWatcher?.watchedPaths == paths { return }
            listingWatcherTask?.cancel()
            listingWatcherTask = nil
            if let listingWatcher { await listingWatcher.stop() }
            listingWatcher = nil
            guard let watcher = RecursivePathWatcher(paths: paths) else { return }
            listingWatcher = watcher
            listingWatcherTask = Task { @MainActor [weak self] in
                for await _ in watcher.events {
                    guard let self else { break }
                    refresh()
                }
            }
        }
    }

    private func reconcileStatusWatcher(path: String) {
        guard lifecyclePhase == .running,
              visiblePaths.contains(path),
              worktrees.contains(where: { $0.path == path && !$0.isPrunable }) else {
            return
        }
        statusWatcherInstallTasks[path]?.cancel()
        statusWatcherInstallTasks[path] = Task { [weak self] in
            guard let self else { return }
            let paths = await git.statusWatchPaths(worktreePath: path)
            guard !Task.isCancelled,
                  lifecyclePhase == .running,
                  visiblePaths.contains(path) else {
                return
            }
            if statusWatchers[path]?.watchedPaths == paths { return }
            statusWatcherTasks[path]?.cancel()
            statusWatcherTasks[path] = nil
            if let watcher = statusWatchers.removeValue(forKey: path) {
                await watcher.stop()
            }
            guard let watcher = RecursivePathWatcher(paths: paths) else { return }
            statusWatchers[path] = watcher
            statusWatcherTasks[path] = Task { @MainActor [weak self] in
                for await _ in watcher.events {
                    guard let self else { break }
                    guard let worktree = worktrees.first(where: { $0.path == path }) else {
                        refresh()
                        continue
                    }
                    guard prepareStatusProbe(for: worktree) else { continue }
                    scheduleStatusRefresh(path: path)
                }
            }
        }
    }

    private func stopStatusTracking(path: String) {
        statusScheduler.remove(path: path)
        statusWatcherInstallTasks.removeValue(forKey: path)?.cancel()
        statusWatcherTasks.removeValue(forKey: path)?.cancel()
        if let watcher = statusWatchers.removeValue(forKey: path) {
            Task { await watcher.stop() }
        }
    }

    private func prepareStatusProbe(for worktree: WorktreeSidebarWorktree) -> Bool {
        guard !requiresListingRefresh(for: worktree) else {
            requestListingRefreshForStaleWorktree(path: worktree.path)
            return false
        }
        staleStatusRefreshPaths.remove(worktree.path)
        return true
    }

    private func requiresListingRefresh(for worktree: WorktreeSidebarWorktree) -> Bool {
        guard !worktree.isPrunable else { return false }
        guard FileManager.default.fileExists(atPath: worktree.path) else { return true }
        guard !worktree.isMain, !worktree.isBare else { return false }
        let marker = URL(fileURLWithPath: worktree.path, isDirectory: true)
            .appendingPathComponent(".git", isDirectory: false)
        return !FileManager.default.fileExists(atPath: marker.path)
    }

    private func requestListingRefreshForStaleWorktree(path: String) {
        statusScheduler.remove(path: path)
        statusByPath[path] = .unavailable
        rebuildRows()
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

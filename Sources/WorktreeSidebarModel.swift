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
    @ObservationIgnored private var statusRefreshPendingPaths: Set<String> = []
    @ObservationIgnored private var listingRequestID: UInt64 = 0
    @ObservationIgnored private var nextStatusRequestID: UInt64 = 0
    @ObservationIgnored private var statusRequestIDs: [String: UInt64] = [:]
    @ObservationIgnored private var listingTask: Task<Void, Never>?
    @ObservationIgnored private var listingWatcherInstallTask: Task<Void, Never>?
    @ObservationIgnored private var listingWatcher: RecursivePathWatcher?
    @ObservationIgnored private var listingWatcherTask: Task<Void, Never>?
    @ObservationIgnored private var statusTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var statusWatcherInstallTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var statusWatchers: [String: RecursivePathWatcher] = [:]
    @ObservationIgnored private var statusWatcherTasks: [String: Task<Void, Never>] = [:]

    init(
        projectRootPath: String,
        git: (any WorktreeSidebarGitOperating)? = nil,
        dialogs: WorktreeSidebarDialogPresenter? = nil,
        workspaces: WorktreeSidebarWorkspaceController
    ) {
        self.projectRootPath = projectRootPath
        self.git = git ?? WorktreeSidebarGitService()
        self.dialogs = dialogs ?? WorktreeSidebarDialogPresenter()
        self.workspaces = workspaces
    }

    var isRefreshing: Bool { listingPhase == .loading }
    var isBusy: Bool { operationPhase != .idle }
    var isInitialLoading: Bool { rows.isEmpty && listingPhase == .loading }

    func start() {
        guard lifecyclePhase == .stopped else { return }
        lifecyclePhase = .running
        refresh()
        reconcileListingWatcher()
    }

    func stop() {
        lifecyclePhase = .stopped
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
            requestStatusRefresh(path: path)
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
        guard !row.worktree.isPrunable else { return }
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

                let closePlan = workspaces.closePlan(
                    worktreePath: inspection.worktree.path,
                    fallbackDirectory: projectRootPath
                )
                operationPhase = .removing(row.id)
                let result = try await git.removeWorktree(
                    projectRootPath: projectRootPath,
                    expected: inspection,
                    force: force
                )
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
        requestStatusRefresh(path: path)
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
        visiblePaths.formIntersection(validPaths)
        for worktree in worktrees where worktree.isPrunable {
            statusByPath[worktree.path] = .unavailable
            stopStatusTracking(path: worktree.path)
        }
        rebuildRows()
        for path in visiblePaths {
            requestStatusRefresh(path: path)
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

    private func requestStatusRefresh(path: String) {
        guard lifecyclePhase == .running,
              visiblePaths.contains(path),
              worktrees.contains(where: { $0.path == path && !$0.isPrunable }) else {
            return
        }
        if statusTasks[path] != nil {
            statusRefreshPendingPaths.insert(path)
            return
        }
        if statusByPath[path] == nil || statusByPath[path] == .unknown {
            statusByPath[path] = .loading
            rebuildRows()
        }
        nextStatusRequestID &+= 1
        let requestID = nextStatusRequestID
        statusRequestIDs[path] = requestID
        let task = Task { [weak self] in
            guard let self else { return }
            let status: WorktreeSidebarStatus
            do {
                status = try await git.isDirty(
                    projectRootPath: projectRootPath,
                    worktreePath: path
                ) ? .dirty : .clean
            } catch {
                status = .unavailable
            }
            guard !Task.isCancelled,
                  lifecyclePhase == .running,
                  statusRequestIDs[path] == requestID else {
                return
            }
            statusTasks[path] = nil
            statusRequestIDs[path] = nil
            if visiblePaths.contains(path) {
                statusByPath[path] = status
                rebuildRows()
            }
            if statusRefreshPendingPaths.remove(path) != nil {
                requestStatusRefresh(path: path)
            }
        }
        statusTasks[path] = task
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
                    let marker = URL(fileURLWithPath: path, isDirectory: true)
                        .appendingPathComponent(".git", isDirectory: false)
                    if FileManager.default.fileExists(atPath: marker.path) {
                        requestStatusRefresh(path: path)
                    } else {
                        refresh()
                    }
                }
            }
        }
    }

    private func stopStatusTracking(path: String) {
        statusTasks.removeValue(forKey: path)?.cancel()
        statusRequestIDs[path] = nil
        statusRefreshPendingPaths.remove(path)
        statusWatcherInstallTasks.removeValue(forKey: path)?.cancel()
        statusWatcherTasks.removeValue(forKey: path)?.cancel()
        if let watcher = statusWatchers.removeValue(forKey: path) {
            Task { await watcher.stop() }
        }
    }

    private static func details(for error: Error) -> String {
        guard let gitError = error as? WorktreeSidebarGitError else { return "" }
        if case .commandFailed(_, let details) = gitError {
            return String(details.prefix(2_000))
        }
        return ""
    }
}

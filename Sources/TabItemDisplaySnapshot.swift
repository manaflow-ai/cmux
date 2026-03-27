import Combine
import Foundation

// MARK: - TabItemDisplaySnapshot

/// Immutable value snapshot of all display-driving state for a single workspace sidebar row.
/// Passed as a `let` parameter to `TabItemView` so that the view never holds a direct
/// `@ObservedObject` subscription to `Workspace`. Only `WorkspaceDisplayPublisher` subscribes
/// to the workspace; it re-publishes only when the snapshot actually changes, preventing
/// spurious body re-evaluations caused by high-frequency `@Published` updates (e.g. port scanner).
struct TabItemDisplaySnapshot: Equatable {
    // Title
    let title: String
    let customTitle: String?           // non-nil = hasCustomTitle

    // Basic flags
    let isPinned: Bool
    let customColor: String?

    // Workspace group state
    let hasChildren: Bool
    let isCollapsed: Bool
    let hasStartupCommand: Bool

    // Prompt / terminal state
    let isAtPrompt: Bool
    let hasFocusedTerminalPanel: Bool

    // Port scanner
    let listeningPorts: [Int]

    // Sidebar content — pre-computed, ordered
    let orderedPanelIds: [UUID]
    let gitBranches: [SidebarGitBranchState]
    let branchDirectoryEntries: [SidebarBranchOrdering.BranchDirectoryEntry]
    let directories: [String]
    let pullRequests: [SidebarPullRequestState]
    let statusEntries: [SidebarStatusEntry]
    let metadataBlocks: [SidebarMetadataBlock]
    let logEntries: [SidebarLogEntry]
    let progress: SidebarProgressState?

    // Remote connection
    let remoteConnectionState: WorkspaceRemoteConnectionState
    let remoteConnectionDetail: String?
    let remoteDisplayTarget: String?
    let hasActiveRemoteTerminalSessions: Bool
    let remoteStatusEntry: SidebarStatusEntry?  // statusEntries["remote.error"]
}

// MARK: - WorkspaceDisplayPublisher

/// `ObservableObject` wrapper around `TabItemDisplaySnapshot` that coalesces
/// `Workspace.objectWillChange` notifications and only re-publishes when the computed
/// snapshot actually differs from the previous one.
///
/// Usage: each `Workspace` owns one `WorkspaceDisplayPublisher`. `VerticalTabsSidebar`
/// passes `workspace.displayPublisher.snapshot` as a `let` parameter to `TabItemView`.
@MainActor
final class WorkspaceDisplayPublisher: ObservableObject {
    @Published private(set) var snapshot: TabItemDisplaySnapshot

    private var cancellable: AnyCancellable?
    private var pendingRefresh = false

    init(workspace: Workspace) {
        self.snapshot = workspace.computeDisplaySnapshot()
        self.cancellable = workspace.objectWillChange
            .sink { [weak self, weak workspace] _ in
                guard let self, !self.pendingRefresh else { return }
                self.pendingRefresh = true
                // Defer to next run-loop turn so all @Published mutations in this cycle
                // have been applied before we re-compute the snapshot.
                DispatchQueue.main.async { [weak self, weak workspace] in
                    self?.pendingRefresh = false
                    guard let self, let workspace else { return }
                    let new = workspace.computeDisplaySnapshot()
                    guard new != self.snapshot else { return }
                    self.snapshot = new
                }
            }
    }
}

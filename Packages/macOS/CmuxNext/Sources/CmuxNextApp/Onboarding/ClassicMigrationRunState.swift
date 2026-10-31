import CmuxNextDaemon
import CmuxNextDaemonService
import CmuxNextOnboarding
import Foundation

/// A classic workspace and the index of the classic window it belongs to.
struct ClassicWorkspaceTurn: Sendable {
    var index: Int
    var saved: ClassicSessionWorkspace
}

/// One run's state, which each workspace it makes writes.
@MainActor
final class ClassicMigrationRunState {
    var ledger: ClassicMigrationLedger
    var outcome: ClassicMigrationOutcome
    /// Who started the run (only the launch's run parks background workspaces).
    let mode: ClassicMigrationPlanner.Mode
    let plan: ClassicMigrationPlan
    /// cmux-next group ids by classic group id.
    let groups: [String: WorkspaceGroupID]
    /// The daemon of each SSH destination, connecting since the run's start.
    let hosts: [String: DaemonService]
    let repository: ClassicMigrationRepository
    /// The window each classic window's workspaces go to, by index.
    let targets: [String]
    var unreachable = Set<String>()
    var lastError: (any Error)?
    var reveal: String?
    var openedInFirstWindow = false
    /// Hears the share of the plan's workspaces handled so far.
    let progress: (@MainActor (Double) -> Void)?
    private var handledCount = 0

    init(ledger: ClassicMigrationLedger, outcome: ClassicMigrationOutcome, mode: ClassicMigrationPlanner.Mode, plan: ClassicMigrationPlan,
         groups: [String: WorkspaceGroupID], hosts: [String: DaemonService], repository: ClassicMigrationRepository,
         progress: (@MainActor (Double) -> Void)? = nil, targets: [String]) {
        self.ledger = ledger
        self.outcome = outcome
        self.mode = mode
        self.plan = plan
        self.groups = groups
        self.hosts = hosts
        self.repository = repository
        self.targets = targets
        self.progress = progress
    }

    /// One more of the plan's workspaces was handled: opened, left in classic or failed.
    func handled() {
        handledCount += 1
        progress?(Double(handledCount) / Double(max(plan.workspaces.count, 1)))
    }
}

/// Classic's session as read, the save it came from, and the files to back up.
struct ClassicSnapshotRead {
    var snapshot: ClassicSessionSnapshot
    var source: ClassicMigrationSource
    var backups: [URL]
}

import Foundation
import Observation

/// The signed-in account and cmux team a CodeRouter account snapshot belongs to.
struct CoderouterAccountScope: Hashable {
    let teamID: String
    let identityID: String?

    init?(teamID: String?, identityID: String?) {
        guard let teamID = teamID?.trimmingCharacters(in: .whitespacesAndNewlines), !teamID.isEmpty else {
            return nil
        }
        self.teamID = teamID
        self.identityID = identityID
    }
}

/// The organization established by the last successful read.
struct CoderouterAccountDestination: Equatable {
    let organizationID: String
}

/// What New Account can do for the selected scope right now.
enum CoderouterAddAvailability: Equatable {
    case ready(CoderouterAccountDestination)
    /// The first read for this scope has not finished.
    case loading
    /// The last read failed; the failure names what to fix.
    case failed(CoderouterCLIFailure)
}

private struct CoderouterAccountRemovalKey: Hashable {
    let scope: CoderouterAccountScope
    let accountID: String
}

/// Owns the sidebar snapshot and the scope it belongs to.
///
/// Team and signed-in identity changes clear rows synchronously. A read from a
/// previous scope can therefore never repopulate the current sidebar, and a
/// New Account action is available only after a successful read for the scope
/// that is still selected.
struct CoderouterAccountState: Equatable {
    private(set) var scope: CoderouterAccountScope?
    private(set) var accounts: [CloudTreeNode.CoderouterAccount] = []
    private(set) var destination: CoderouterAccountDestination?
    private(set) var isLoadingScope = false
    /// Why the last read for this scope failed, until a read succeeds or the
    /// scope changes. Lets the sidebar say what is wrong instead of "loading".
    private(set) var failure: CoderouterCLIFailure?
    private(set) var pendingRemovalIDs: Set<String> = []
    /// Removals whose CLI write succeeded but whose next account read has not
    /// confirmed that the row is gone yet. These IDs remain filtered so a
    /// stale post-action read cannot briefly put a removed account back.
    private var pendingRemovalKeys: Set<CoderouterAccountRemovalKey> = []
    private var completedRemovalKeys: Set<CoderouterAccountRemovalKey> = []
    /// Every read and mutation gets a revision. A response from an older
    /// revision must never overwrite newer post-action state.
    private var revision: UInt64 = 0

    mutating func select(_ newScope: CoderouterAccountScope?) {
        guard newScope != scope else { return }
        revision &+= 1
        scope = newScope
        accounts = []
        destination = nil
        failure = nil
        pendingRemovalIDs = pendingIDs(for: newScope)
        isLoadingScope = newScope != nil
    }

    /// Drops the snapshot before the auth coordinator publishes the next
    /// confirmed team. The scope observer can run before SwiftUI observes the
    /// new team ID, so selecting the current scope here would otherwise leave
    /// the previous team's rows visible through that gap.
    mutating func resetForTeamScopeChange() {
        revision &+= 1
        scope = nil
        accounts = []
        destination = nil
        failure = nil
        pendingRemovalIDs = []
        isLoadingScope = false
    }

    /// Starts a read for the current scope and invalidates all older reads.
    /// The returned revision must be supplied to ``apply`` or ``fail``.
    mutating func beginRefresh(for readScope: CoderouterAccountScope) -> UInt64? {
        guard readScope == scope else { return nil }
        revision &+= 1
        return revision
    }

    mutating func invalidateDestination(for refreshScope: CoderouterAccountScope) {
        guard refreshScope == scope else { return }
        destination = nil
    }

    @discardableResult
    mutating func apply(
        accounts newAccounts: [CloudTreeNode.CoderouterAccount],
        organizationID: String,
        for readScope: CoderouterAccountScope,
        startedAt readRevision: UInt64? = nil
    ) -> Bool {
        guard readScope == scope,
              readRevision == nil || readRevision == revision else { return false }
        let returnedIDs = Set(newAccounts.map(\.id))
        // A successful removal stays pending until a read that began after the
        // write omits the ID. The first read can still be stale, so do not let
        // it publish an incorrect intermediate row.
        let confirmedRemovals = completedRemovalKeys.filter {
            $0.scope == readScope && !returnedIDs.contains($0.accountID)
        }
        for removal in confirmedRemovals {
            pendingRemovalKeys.remove(removal)
            completedRemovalKeys.remove(removal)
        }
        pendingRemovalIDs = pendingIDs(for: readScope)
        accounts = newAccounts.filter { !pendingRemovalIDs.contains($0.id) }
        destination = CoderouterAccountDestination(organizationID: organizationID)
        failure = nil
        isLoadingScope = false
        return true
    }

    mutating func fail(
        _ readFailure: CoderouterCLIFailure,
        for readScope: CoderouterAccountScope,
        startedAt readRevision: UInt64? = nil
    ) {
        guard readScope == scope,
              readRevision == nil || readRevision == revision else { return }
        destination = nil
        failure = readFailure
        isLoadingScope = false
    }

    func destination(for requestScope: CoderouterAccountScope?) -> CoderouterAccountDestination? {
        guard let requestScope, requestScope == scope else { return nil }
        return destination
    }

    /// A failure is reported only for the scope it was read for; a scope that
    /// has not finished its first read is loading, never failed.
    func addAvailability(for requestScope: CoderouterAccountScope?) -> CoderouterAddAvailability {
        guard let requestScope, requestScope == scope else { return .loading }
        if let destination { return .ready(destination) }
        if let failure { return .failed(failure) }
        return .loading
    }

    func removalScope(selected: CoderouterAccountScope?) -> CoderouterAccountScope? {
        guard let scope, scope == selected else { return nil }
        return scope
    }

    mutating func removeOptimistically(accountID: String, for removeScope: CoderouterAccountScope) -> Int? {
        guard removeScope == scope,
              let index = accounts.firstIndex(where: { $0.id == accountID }) else { return nil }
        let removal = CoderouterAccountRemovalKey(scope: removeScope, accountID: accountID)
        accounts.remove(at: index)
        pendingRemovalKeys.insert(removal)
        completedRemovalKeys.remove(removal)
        pendingRemovalIDs.insert(accountID)
        revision &+= 1
        return index
    }

    /// Marks the CLI write as successful while retaining the pending filter.
    /// The next authoritative read clears it only after the account is absent.
    mutating func finishRemoval(accountID: String, for removeScope: CoderouterAccountScope) {
        let removal = CoderouterAccountRemovalKey(scope: removeScope, accountID: accountID)
        guard pendingRemovalKeys.contains(removal) else { return }
        completedRemovalKeys.insert(removal)
        revision &+= 1
    }

    mutating func restore(
        _ account: CloudTreeNode.CoderouterAccount,
        at index: Int,
        for removeScope: CoderouterAccountScope
    ) {
        let removal = CoderouterAccountRemovalKey(scope: removeScope, accountID: account.id)
        pendingRemovalKeys.remove(removal)
        completedRemovalKeys.remove(removal)
        revision &+= 1
        guard removeScope == scope else { return }
        pendingRemovalIDs.remove(account.id)
        guard !accounts.contains(where: { $0.id == account.id }) else { return }
        accounts.insert(account, at: min(index, accounts.endIndex))
    }

    private func pendingIDs(for pendingScope: CoderouterAccountScope?) -> Set<String> {
        guard let pendingScope else { return [] }
        return Set(
            pendingRemovalKeys
                .filter { $0.scope == pendingScope }
                .map(\.accountID)
        )
    }
}

/// Serializes reads and removals so a removal never interleaves with another
/// team's read and the post-removal read sees the write.
@MainActor
final class CoderouterCLIOperationLane {
    /// Shared by every window so their sidebars observe one order of writes.
    static let shared = CoderouterCLIOperationLane()

    private var tail: Task<Void, Never>?
    private var generation = 0

    func run(_ operation: @escaping @MainActor () async -> Void) async {
        let task = enqueue(operation)
        await withTaskCancellationHandler(
            operation: { await task.value },
            onCancel: { task.cancel() }
        )
    }

    @discardableResult
    func enqueue(_ operation: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let previous = tail
        generation += 1
        let taskGeneration = generation
        let task = Task { @MainActor in
            defer {
                if generation == taskGeneration {
                    tail = nil
                }
            }
            await previous?.value
            guard !Task.isCancelled else { return }
            await operation()
        }
        tail = task
        return task
    }
}

/// Owns CodeRouter sidebar state for the lifetime of one sidebar surface.
///
/// `MachinesPanelView` is remounted when the right-sidebar mode changes. The
/// account snapshot and the CLI lane must therefore outlive that view together:
/// otherwise a new read can overlap a removal that the old view started, and
/// the new view loses the tombstone that keeps a stale account hidden.
@MainActor
@Observable
final class CoderouterAccountStore {
    var state = CoderouterAccountState()
    var isRefreshing = false
    var refreshRequest = 0
    @ObservationIgnored let lane = CoderouterCLIOperationLane.shared
    @ObservationIgnored private var addGeneration: UInt64 = 0
    @ObservationIgnored private var addTask: Task<Void, Never>?

    @ObservationIgnored private var scopeChangeObserver: NSObjectProtocol?

    init() {
        // Configurations a crash or a killed setup terminal left behind.
        Task.detached(priority: .utility) { CoderouterAppCLISession.sweepAllStaleSessions() }
        scopeChangeObserver = NotificationCenter.default.addObserver(
            forName: .cmuxCloudTeamScopeDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.resetForTeamScopeChange()
            }
        }
    }

    deinit {
        if let scopeChangeObserver {
            NotificationCenter.default.removeObserver(scopeChangeObserver)
        }
    }

    /// Clears retained rows even while the Machines view is unmounted. The
    /// store owner must invalidate the snapshot before the next scope can be
    /// rendered, then request a read when the panel mounts again.
    func resetForTeamScopeChange() {
        cancelAddTask()
        state.resetForTeamScopeChange()
        isRefreshing = true
        refreshRequest &+= 1
    }

    /// Starts a New Account operation. The token becomes stale when the
    /// selected scope or owning sidebar disappears, so a suspended task cannot
    /// launch setup for an account that is no longer current.
    func beginAddTask() -> UInt64 {
        addGeneration &+= 1
        return addGeneration
    }

    /// Starts the caller-owned Add Account operation. Scope changes and view
    /// disappearance cancel this task, while the generation still fences any
    /// result that races cancellation.
    func startAddTask(_ operation: @escaping @MainActor (UInt64) async -> Void) {
        cancelAddTask()
        let generation = beginAddTask()
        addTask = Task { @MainActor [weak self] in
            await operation(generation)
            guard let self, self.isCurrentAddTask(generation) else { return }
            self.addTask = nil
        }
    }

    func cancelAddTask() {
        addTask?.cancel()
        addTask = nil
        addGeneration &+= 1
    }

    func isCurrentAddTask(_ generation: UInt64) -> Bool {
        addGeneration == generation
    }
}

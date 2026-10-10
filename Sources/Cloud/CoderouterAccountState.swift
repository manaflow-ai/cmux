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

/// The organization and command mode established by the last successful read.
struct CoderouterAccountDestination: Equatable {
    let organizationID: String
    let teamScope: CoderouterTeamScope
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
        teamScope: CoderouterTeamScope,
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
        destination = CoderouterAccountDestination(organizationID: organizationID, teamScope: teamScope)
        isLoadingScope = false
        return true
    }

    mutating func fail(for readScope: CoderouterAccountScope, startedAt readRevision: UInt64? = nil) {
        guard readScope == scope,
              readRevision == nil || readRevision == revision else { return }
        destination = nil
        isLoadingScope = false
    }

    func destination(for requestScope: CoderouterAccountScope?) -> CoderouterAccountDestination? {
        guard let requestScope, requestScope == scope else { return nil }
        return destination
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

/// Serializes reads and removals because older CodeRouter CLIs store their
/// active organization in a shared config file.
@MainActor
final class CoderouterCLIOperationLane {
    /// CodeRouter's legacy CLI stores its active organization in one shared
    /// configuration file, so serialization must cover every window.
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
}

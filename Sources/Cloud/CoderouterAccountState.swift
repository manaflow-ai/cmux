import Foundation

/// The signed-in account and cmux team a CodeRouter account snapshot belongs to.
struct CoderouterAccountScope: Hashable {
    let teamID: String
    let identityID: String?

    /// Nil while no team is selected; the sidebar then shows no accounts.
    init?(teamID: String?, identityID: String?) {
        guard let teamID = teamID?.trimmingCharacters(in: .whitespacesAndNewlines), !teamID.isEmpty else { return nil }
        self.teamID = teamID
        self.identityID = identityID
    }
}

/// Where a New Account row may create an account: the organization the last
/// successful read mapped the team to, and the mechanism that read proved the
/// CLI supports.
struct CoderouterAccountDestination: Equatable {
    let organizationID: String
    let teamScope: CoderouterTeamScope
}

/// The sidebar's CodeRouter account rows, keyed by the team they were read for.
///
/// Rules: a different team (or account) clears the rows immediately and shows
/// the loading state until that team's first read; a failed read keeps the
/// rows only when it was for the team still shown; results for any other team
/// are dropped. A destination for New Account exists only between a successful
/// read and the next refresh, so a slow or failed read never authorizes a
/// create against an older mapping.
struct CoderouterAccountState: Equatable {
    private(set) var scope: CoderouterAccountScope?
    private(set) var accounts: [CloudTreeNode.CoderouterAccount] = []
    private(set) var destination: CoderouterAccountDestination?
    /// True from a scope change until that scope's first read finishes.
    private(set) var isLoadingScope = false
    /// The organization the last successful read for this scope used; reused
    /// by legacy CLIs to skip another catalog read.
    private(set) var knownOrganizationID: String?
    /// Rows the user is removing. A read that started before the removal
    /// finished must not bring them back.
    private(set) var pendingRemovalIDs: Set<String> = []

    /// Selects the team whose accounts are shown.
    mutating func select(_ newScope: CoderouterAccountScope?) {
        guard newScope != scope else { return }
        scope = newScope
        accounts = []
        destination = nil
        knownOrganizationID = nil
        pendingRemovalIDs = []
        isLoadingScope = newScope != nil
    }

    /// A refresh for the shown scope is starting.
    mutating func beginRefresh(for refreshScope: CoderouterAccountScope) {
        guard refreshScope == scope else { return }
        destination = nil
    }

    /// Applies a successful read. Returns false when the read belongs to a
    /// team that is no longer shown.
    @discardableResult
    mutating func apply(
        accounts newAccounts: [CloudTreeNode.CoderouterAccount],
        organizationID: String,
        teamScope: CoderouterTeamScope,
        for readScope: CoderouterAccountScope
    ) -> Bool {
        guard readScope == scope else { return false }
        accounts = newAccounts.filter { !pendingRemovalIDs.contains($0.id) }
        destination = CoderouterAccountDestination(organizationID: organizationID, teamScope: teamScope)
        knownOrganizationID = organizationID
        isLoadingScope = false
        return true
    }

    /// Records a failed read. Rows stay visible only for the same team.
    mutating func fail(for readScope: CoderouterAccountScope) {
        guard readScope == scope else { return }
        destination = nil
        isLoadingScope = false
    }

    /// The destination for a New Account row on `requestScope`, if a fresh
    /// successful read established one.
    func destination(for requestScope: CoderouterAccountScope?) -> CoderouterAccountDestination? {
        guard let requestScope, requestScope == scope else { return nil }
        return destination
    }

    /// The team a removal of a shown row runs against: the team whose rows
    /// are shown, and only while it is still the selected team. Nil while the
    /// selection has moved on and the old rows have not been cleared yet.
    func removalScope(selected: CoderouterAccountScope?) -> CoderouterAccountScope? {
        guard let scope, scope == selected else { return nil }
        return scope
    }

    /// Hides a row the user is removing; returns where it was so a failed
    /// removal can put it back.
    mutating func removeOptimistically(accountID: String, for removeScope: CoderouterAccountScope) -> Int? {
        guard removeScope == scope,
              let index = accounts.firstIndex(where: { $0.id == accountID }) else { return nil }
        accounts.remove(at: index)
        pendingRemovalIDs.insert(accountID)
        return index
    }

    /// The removal succeeded; later reads no longer list the row anyway.
    mutating func finishRemoval(accountID: String) {
        pendingRemovalIDs.remove(accountID)
    }

    /// Restores a row after a failed removal, unless the team changed or a
    /// newer read already shows it.
    mutating func restore(
        _ account: CloudTreeNode.CoderouterAccount,
        at index: Int,
        for removeScope: CoderouterAccountScope
    ) {
        pendingRemovalIDs.remove(account.id)
        guard removeScope == scope, !accounts.contains(where: { $0.id == account.id }) else { return }
        accounts.insert(account, at: min(index, accounts.endIndex))
    }
}

/// Runs the sidebar's CodeRouter CLI operations one at a time, in order. A
/// removal therefore never overlaps a refresh, and the refresh after it reads
/// the result. Cancelling a waiting caller cancels its operation; an operation
/// that was cancelled before it started does not run.
@MainActor
final class CoderouterCLIOperationLane {
    private var tail: Task<Void, Never>?

    /// Runs `operation` after every operation submitted before it, and
    /// returns when it finishes (or was skipped because it was cancelled).
    func run(_ operation: @escaping @MainActor () async -> Void) async {
        let task = enqueue(operation)
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// Submits `operation` behind the current tail. The returned task can be
    /// cancelled; it then skips the operation if it has not started yet.
    @discardableResult
    func enqueue(_ operation: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let previous = tail
        let task = Task { @MainActor in
            await previous?.value
            guard !Task.isCancelled else { return }
            await operation()
        }
        tail = task
        return task
    }
}

import Foundation

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

    mutating func select(_ newScope: CoderouterAccountScope?) {
        guard newScope != scope else { return }
        scope = newScope
        accounts = []
        destination = nil
        pendingRemovalIDs = []
        isLoadingScope = newScope != nil
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
        for readScope: CoderouterAccountScope
    ) -> Bool {
        guard readScope == scope else { return false }
        accounts = newAccounts.filter { !pendingRemovalIDs.contains($0.id) }
        destination = CoderouterAccountDestination(organizationID: organizationID, teamScope: teamScope)
        isLoadingScope = false
        return true
    }

    mutating func fail(for readScope: CoderouterAccountScope) {
        guard readScope == scope else { return }
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
        accounts.remove(at: index)
        pendingRemovalIDs.insert(accountID)
        return index
    }

    mutating func finishRemoval(accountID: String) {
        pendingRemovalIDs.remove(accountID)
    }

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

/// Serializes reads and removals because older CodeRouter CLIs store their
/// active organization in a shared config file.
@MainActor
final class CoderouterCLIOperationLane {
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

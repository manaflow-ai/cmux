import Foundation
import Observation

/// Persists the user's Cloud machine pins and their stable order per account/team scope.
@MainActor
@Observable
final class CloudMachinePinStore {
    static let defaultsKey = "cloudTree.machinePins.v1"
    private static let removedDefaultMachineKey = "cloud.defaultMachineID"

    private let defaults: UserDefaults
    private let scopeProvider: @MainActor () -> String?
    private var scopes: [String: CloudMachinePinStoreState]
    private var activeScope: String?
    private(set) var pinnedMachineIDs: Set<String> = []

    /// Creates a store backed by the supplied preferences domain.
    /// - Parameters:
    ///   - defaults: Preferences used for persistence.
    ///   - scopeProvider: Returns a stable account/team scope, or nil while signed out.
    init(defaults: UserDefaults, scopeProvider: @escaping @MainActor () -> String?) {
        self.defaults = defaults
        self.scopeProvider = scopeProvider
        scopes = defaults.data(forKey: Self.defaultsKey).flatMap {
            try? JSONDecoder().decode([String: CloudMachinePinStoreState].self, from: $0)
        } ?? [:]
        // A former default machine must never reappear as a designation after migration.
        defaults.removeObject(forKey: Self.removedDefaultMachineKey)
        syncScope()
    }

    /// Refreshes the active account/team scope after authentication changes.
    func refreshScope() {
        syncScope()
    }

    /// Returns whether an immutable machine identity is pinned in the active scope.
    func isPinned(_ machineID: String) -> Bool {
        return pinnedMachineIDs.contains(machineID)
    }

    /// Orders machine identities with pinned machines first while preserving stable order.
    func orderedMachineIDs(_ machineIDs: [String]) -> [String] {
        let current = scopes[activeScope ?? ""] ?? CloudMachinePinStoreState()
        var seen = Set<String>()
        let order = current.order.filter { machineIDs.contains($0) && seen.insert($0).inserted }
            + machineIDs.filter { seen.insert($0).inserted }
        return order.filter { current.pinned.contains($0) } + order.filter { !current.pinned.contains($0) }
    }

    /// Records newly visible machines without treating a partial catalog as a deletion.
    func remember(machineIDs: [String]) {
        syncScope()
        guard let scope = activeScope else { return }
        var current = scopes[scope] ?? CloudMachinePinStoreState()
        var seen = Set(current.order)
        current.order += machineIDs.filter { seen.insert($0).inserted }
        commit(current, scope: scope)
    }

    /// Reconciles the persisted order and removes identities confirmed absent by a full list.
    func reconcile(machineIDs: [String]) {
        syncScope()
        guard let scope = activeScope else { return }
        var current = scopes[scope] ?? CloudMachinePinStoreState()
        var seen = Set<String>()
        let live = machineIDs.filter { seen.insert($0).inserted }
        let liveSet = Set(live)
        let nextOrder = current.order.filter { liveSet.contains($0) } + live.filter { !current.order.contains($0) }
        current.order = nextOrder
        current.pinned.formIntersection(liveSet)
        commit(current, scope: scope)
    }

    /// Pins or unpins one machine without affecting any other machine.
    func setPinned(_ pinned: Bool, machineID: String) {
        syncScope()
        guard let scope = activeScope, !machineID.isEmpty else { return }
        var current = scopes[scope] ?? CloudMachinePinStoreState()
        if !current.order.contains(machineID) { current.order.append(machineID) }
        if pinned { current.pinned.insert(machineID) } else { current.pinned.remove(machineID) }
        let pinnedOrder = current.order.filter { current.pinned.contains($0) }
        let unpinnedOrder = current.order.filter { !current.pinned.contains($0) }
        current.order = pinnedOrder + unpinnedOrder
        commit(current, scope: scope)
    }

    private func syncScope() {
        let nextScope = scopeProvider()?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard nextScope != activeScope else { return }
        activeScope = nextScope?.isEmpty == false ? nextScope : nil
        pinnedMachineIDs = activeScope.flatMap { scopes[$0]?.pinned } ?? []
    }

    private func commit(_ value: CloudMachinePinStoreState, scope: String) {
        guard scopes[scope] != value else { return }
        scopes[scope] = value
        if activeScope == scope { pinnedMachineIDs = value.pinned }
        if let data = try? JSONEncoder().encode(scopes) { defaults.set(data, forKey: Self.defaultsKey) }
    }
}

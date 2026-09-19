import Foundation
import Observation

/// Persists which Cloud machines a person pinned, and the stable order every
/// Machines panel shows them in, per account/team scope.
///
/// Pinned machines sort first. Within the pinned and unpinned groups, machines
/// keep the order they were first seen in, so refreshes, catalog discovery, and
/// asynchronous loading never shuffle the fleet; a newly created machine appends
/// after the existing fleet. A newly pinned machine joins the end of the pinned
/// group (earlier pins stay above it), and unpinning leaves a machine at the top
/// of the unpinned group so nothing else moves.
///
/// The store is `@Observable`, so a view that reads ``pinnedMachineIDs`` or
/// ``isPinned(_:)`` re-renders after ``setPinned(_:machineID:)``. Tests pass a
/// scoped `UserDefaults(suiteName:)` and a closure returning the scope under test:
///
/// ```swift
/// let store = CloudMachinePinStore(defaults: defaults, scopeProvider: { "user:a|team:one" })
/// store.reconcile(machineIDs: ["b", "a"])
/// store.setPinned(true, machineID: "a")
/// store.orderedMachineIDs(["b", "a"]) // ["a", "b"]
/// ```
@MainActor
@Observable
public final class CloudMachinePinStore {
    /// The `UserDefaults` key holding every scope's pins and remembered order.
    /// Pins are independent of ``DefaultCloudMachineStore``: the Cmd+Y default
    /// machine is a routing preference, a pin is a sidebar priority.
    public static let defaultsKey = "cloudTree.machinePins.v1"

    private let defaults: UserDefaults
    private let scopeProvider: @MainActor () -> String?
    private var scopes: [String: CloudMachinePinStoreState]
    private var activeScope: String?

    /// Creates a store backed by the supplied preferences domain.
    ///
    /// - Parameters:
    ///   - defaults: Preferences used for persistence; tests pass a scoped suite.
    ///   - scopeProvider: Returns a stable account/team scope, or nil while
    ///     signed out. Without a scope, pins are neither applied nor persisted.
    public init(defaults: UserDefaults, scopeProvider: @escaping @MainActor () -> String?) {
        self.defaults = defaults
        self.scopeProvider = scopeProvider
        scopes = defaults.data(forKey: Self.defaultsKey).flatMap {
            try? JSONDecoder().decode([String: CloudMachinePinStoreState].self, from: $0)
        } ?? [:]
        syncScope()
    }

    /// Machine identities pinned in the active scope: a projection of the
    /// persisted state, never a second copy of it.
    public var pinnedMachineIDs: Set<String> {
        activeScope.flatMap { scopes[$0]?.pinned } ?? []
    }

    /// Re-reads the account/team scope after sign-in, sign-out, or a team switch.
    public func refreshScope() {
        syncScope()
    }

    /// Whether a machine identity is pinned in the active scope.
    ///
    /// - Parameter machineID: The immutable Cloud machine identity, never its display name.
    public func isPinned(_ machineID: String) -> Bool {
        pinnedMachineIDs.contains(machineID)
    }

    /// Orders visible machine identities: pinned first, then unpinned, each
    /// group in remembered order; identities not remembered yet keep the order
    /// they were given, after the remembered ones.
    ///
    /// - Parameter machineIDs: Every machine identity the panel is about to show.
    /// - Returns: The same identities, deduplicated, in display order.
    public func orderedMachineIDs(_ machineIDs: [String]) -> [String] {
        let current = activeScope.flatMap { scopes[$0] } ?? CloudMachinePinStoreState()
        let visible = Set(machineIDs)
        var seen = Set<String>()
        var order: [String] = []
        order.reserveCapacity(machineIDs.count)
        for id in current.order where visible.contains(id) && seen.insert(id).inserted { order.append(id) }
        for id in machineIDs where seen.insert(id).inserted { order.append(id) }
        return order.filter { current.pinned.contains($0) } + order.filter { !current.pinned.contains($0) }
    }

    /// Appends newly visible machines to the remembered order. A partial list
    /// (a catalog snapshot, one page of a fleet) never removes anything.
    ///
    /// - Parameter machineIDs: Machine identities that became visible.
    public func remember(machineIDs: [String]) {
        syncScope()
        guard let scope = activeScope else { return }
        var current = scopes[scope] ?? CloudMachinePinStoreState()
        var seen = Set(current.order)
        current.order += machineIDs.filter { seen.insert($0).inserted }
        commit(current, scope: scope)
    }

    /// Reconciles the remembered order with the complete set of visible
    /// machines, pruning pins and order entries whose machine is confirmed gone.
    ///
    /// - Parameter machineIDs: Every identity that still has a row: the
    ///   authoritative fleet response plus any catalog-only machine the panel
    ///   keeps showing. An identity absent from this set loses its pin.
    public func reconcile(machineIDs: [String]) {
        syncScope()
        guard let scope = activeScope else { return }
        var current = scopes[scope] ?? CloudMachinePinStoreState()
        var seen = Set<String>()
        let live = machineIDs.filter { seen.insert($0).inserted }
        let liveSet = Set(live)
        let remembered = Set(current.order)
        current.order = current.order.filter { liveSet.contains($0) } + live.filter { !remembered.contains($0) }
        current.pinned.formIntersection(liveSet)
        commit(current, scope: scope)
    }

    /// Pins or unpins one machine without changing any other machine's relative
    /// order: a new pin joins the end of the pinned group, and an unpinned
    /// machine leads the unpinned group.
    ///
    /// - Parameters:
    ///   - pinned: The new pin state.
    ///   - machineID: The immutable Cloud machine identity.
    public func setPinned(_ pinned: Bool, machineID: String) {
        syncScope()
        guard let scope = activeScope, !machineID.isEmpty else { return }
        var current = scopes[scope] ?? CloudMachinePinStoreState()
        if !current.order.contains(machineID) { current.order.append(machineID) }
        if pinned { current.pinned.insert(machineID) } else { current.pinned.remove(machineID) }
        let pins = current.pinned
        current.order = current.order.filter { pins.contains($0) } + current.order.filter { !pins.contains($0) }
        commit(current, scope: scope)
    }

    private func syncScope() {
        let nextScope = scopeProvider()?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard nextScope != activeScope else { return }
        activeScope = nextScope?.isEmpty == false ? nextScope : nil
    }

    private func commit(_ value: CloudMachinePinStoreState, scope: String) {
        guard scopes[scope] != value else { return }
        scopes[scope] = value
        if let data = try? JSONEncoder().encode(scopes) { defaults.set(data, forKey: Self.defaultsKey) }
    }
}

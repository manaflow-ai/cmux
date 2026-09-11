import Foundation

/// The last thing this app learned about whether the signed-in account owns
/// any Cloud machine, kept in `UserDefaults` so the next launch can decide
/// what Cloud work to do without a control-plane request.
///
/// Written only by ``VMClient`` (every machine list, every create, fork, and
/// restore) and cleared when Cloud access ends (sign-out), so it never
/// outlives the account it describes. `nil` means this build has not listed
/// the fleet yet.
struct CloudMachineCache: Sendable {
    static let hasAnyMachineKey = "cloud.machines.cachedHasAny"

    // nonisolated(unsafe): UserDefaults is documented thread-safe but the SDK
    // does not mark it Sendable; this is an immutable handle, never mutated.
    nonisolated(unsafe) private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Whether the account had at least one machine the last time this build
    /// listed or created one; `nil` before the first list.
    var hasAnyMachine: Bool? {
        guard defaults.object(forKey: Self.hasAnyMachineKey) != nil else { return nil }
        return defaults.bool(forKey: Self.hasAnyMachineKey)
    }

    /// Remember the answer; a repeated identical answer (every fleet poll)
    /// writes nothing.
    func record(hasAnyMachine: Bool) {
        guard self.hasAnyMachine != hasAnyMachine else { return }
        defaults.set(hasAnyMachine, forKey: Self.hasAnyMachineKey)
    }

    /// Forget the fleet: the next account starts from "not listed yet".
    func clear() {
        defaults.removeObject(forKey: Self.hasAnyMachineKey)
    }
}

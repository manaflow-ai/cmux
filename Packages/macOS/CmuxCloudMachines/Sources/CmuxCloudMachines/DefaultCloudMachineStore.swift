import Foundation
import Observation

/// Owns the user's persisted default-machine selection and its observable projection.
@MainActor
@Observable
public final class DefaultCloudMachineStore {
    /// The existing preference key, preserved across the extraction.
    public static let defaultsKey = "cloud.defaultMachineID"
    private let defaults: UserDefaults

    /// The selected machine identity, or nil before the first authoritative selection.
    public var machineID: String? {
        didSet {
            if let machineID, !machineID.isEmpty {
                defaults.set(machineID, forKey: Self.defaultsKey)
            } else {
                defaults.removeObject(forKey: Self.defaultsKey)
            }
        }
    }

    /// Loads the selected identity from an explicitly supplied preferences domain.
    /// - Parameter defaults: App preferences, or a private suite in tests.
    public init(defaults: UserDefaults) {
        self.defaults = defaults
        machineID = defaults.string(forKey: Self.defaultsKey)
    }

    /// Resolves a selection without allowing a partial catalog to replace it.
    ///
    /// An empty list preserves the stored preference. A complete nonempty list may
    /// replace a deleted machine; a partial list may only confirm the existing one.
    /// - Parameters:
    ///   - machines: The observed machines.
    ///   - isComplete: True only for a fresh successful control-plane list response.
    /// - Returns: A confirmed machine ID, or nil if the observation cannot select one.
    public func resolveMachineID(from machines: [CloudMachineDescriptor], isComplete: Bool = false) -> String? {
        if let machineID, machines.contains(where: { $0.id == machineID }) { return machineID }
        guard isComplete, let chosen = Self.chooseMachine(machines) else { return nil }
        machineID = chosen.id
        return chosen.id
    }

    /// Selects in one pass, preferring desktops and then immutable machine IDs.
    /// - Parameter machines: Candidate machines in any order.
    /// - Returns: The preferred machine, or nil for an empty list.
    public nonisolated static func chooseMachine(_ machines: [CloudMachineDescriptor]) -> CloudMachineDescriptor? {
        machines.min {
            if $0.isDesktop != $1.isDesktop { return $0.isDesktop }
            return $0.id < $1.id
        }
    }
}

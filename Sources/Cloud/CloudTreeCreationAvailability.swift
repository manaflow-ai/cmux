import Foundation

/// The panel's single source of truth for whether a creation target is usable.
enum CloudTreeCreationAvailability: Equatable {
    case allowed
    case expired
    case unknown

    static func resolve(machine: SurfaceMachineID, machines: [MachineSnapshot]) -> Self {
        if machine.isLocal { return .allowed }
        guard let snapshot = machines.first(where: { .cloud($0.id) == machine }) else { return .unknown }
        return snapshot.freeAccess == .expired ? .expired : .allowed
    }
}

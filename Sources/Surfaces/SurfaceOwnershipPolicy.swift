import Foundation

/// A destination's ownership rule, independent of UI, drag payloads, and I/O.
struct SurfaceOwnershipPolicy: Equatable, Sendable {
    let cloudMachine: SurfaceMachineID?

    func rejection(for source: SurfaceMachineID?) -> SurfaceTransferRejection? {
        guard let cloudMachine else { return nil }
        return source == cloudMachine ? nil : .cloudMachineMismatch
    }

    func rejection(for resources: [SurfaceResourceID]) -> SurfaceTransferRejection? {
        guard cloudMachine != nil else { return nil }
        return resources.isEmpty || resources.contains(where: { rejection(for: $0.machine) != nil })
            ? .cloudMachineMismatch : nil
    }
}

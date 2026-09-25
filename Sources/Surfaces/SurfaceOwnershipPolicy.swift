import CmuxSurfaceCatalogModel
import Foundation

/// A destination's ownership rule, independent of UI, drag payloads, and I/O.
struct SurfaceOwnershipPolicy: Equatable, Sendable {
    let cloudMachine: SurfaceMachineID?

    func rejection(for source: SurfaceMachineID?) -> SurfaceTransferRejection? {
        guard let cloudMachine else { return nil }
        return source == cloudMachine ? nil : .cloudMachineMismatch
    }

    func rejection(for resources: [SurfaceResourceID]) -> SurfaceTransferRejection? {
        rejection(for: resources.map(\.machine))
    }

    func rejection(for machines: [SurfaceMachineID]) -> SurfaceTransferRejection? {
        guard cloudMachine != nil else { return nil }
        return machines.isEmpty || machines.contains(where: { rejection(for: $0) != nil })
            ? .cloudMachineMismatch : nil
    }
}

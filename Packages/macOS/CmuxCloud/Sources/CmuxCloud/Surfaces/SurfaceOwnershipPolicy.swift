import CmuxSurfaceCatalogModel
import Foundation

/// A destination's ownership rule, independent of UI, drag payloads, and I/O.
public struct SurfaceOwnershipPolicy: Equatable, Sendable {
    public init(
        cloudMachine: SurfaceMachineID?
    ) {
        self.cloudMachine = cloudMachine
    }

    public let cloudMachine: SurfaceMachineID?

    public func rejection(for source: SurfaceMachineID?) -> SurfaceTransferRejection? {
        guard let cloudMachine else { return nil }
        return source == cloudMachine ? nil : .cloudMachineMismatch
    }

    public func rejection(for resources: [SurfaceResourceID]) -> SurfaceTransferRejection? {
        rejection(for: resources.map(\.machine))
    }

    public func rejection(for machines: [SurfaceMachineID]) -> SurfaceTransferRejection? {
        guard cloudMachine != nil else { return nil }
        return machines.isEmpty || machines.contains(where: { rejection(for: $0) != nil })
            ? .cloudMachineMismatch : nil
    }
}

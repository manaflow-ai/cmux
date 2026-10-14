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

    public func rejection(for source: SurfaceMachineID?, kind: SurfaceResourceKind? = nil) -> SurfaceTransferRejection? {
        guard kind != .browser, let cloudMachine else { return nil }
        return source == cloudMachine ? nil : .cloudMachineMismatch
    }

    public func rejection(for resources: [SurfaceResourceID]) -> SurfaceTransferRejection? {
        guard cloudMachine != nil else { return nil }
        guard !resources.isEmpty else { return .cloudMachineMismatch }
        let ownedResources = resources.filter { $0.kind != .browser }
        guard !ownedResources.isEmpty else { return nil }
        return ownedResources.contains(where: { rejection(for: $0.machine, kind: $0.kind) != nil })
            ? .cloudMachineMismatch : nil
    }

    public func rejection(for machines: [SurfaceMachineID]) -> SurfaceTransferRejection? {
        guard cloudMachine != nil else { return nil }
        return machines.isEmpty || machines.contains(where: { rejection(for: $0) != nil })
            ? .cloudMachineMismatch : nil
    }
}

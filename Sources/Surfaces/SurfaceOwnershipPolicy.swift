import CmuxSurfaceCatalogModel
import Foundation

/// App-facing rejection mapping for the pure package ownership rule.
extension SurfaceOwnershipPolicy {
    func rejection(for source: SurfaceMachineID?) -> SurfaceTransferRejection? {
        allows(source: source) ? nil : .cloudMachineMismatch
    }

    func rejection(for resources: [SurfaceResourceID]) -> SurfaceTransferRejection? {
        allows(resources: resources) ? nil : .cloudMachineMismatch
    }

    func rejection(for machines: [SurfaceMachineID]) -> SurfaceTransferRejection? {
        allows(machines: machines) ? nil : .cloudMachineMismatch
    }
}

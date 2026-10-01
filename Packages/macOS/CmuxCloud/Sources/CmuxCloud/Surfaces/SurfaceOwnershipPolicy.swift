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
        guard cloudMachine != nil else { return nil }
        guard !resources.isEmpty else { return .cloudMachineMismatch }
        // Local browser panels are portable UI surfaces: moving one into a
        // Cloud workspace keeps the page in the app and does not move a
        // terminal or other machine-owned resource. Local terminals remain
        // rejected, and mixed browser/terminal groups still fail closed.
        return resources.contains {
            let portableLocalBrowser = $0.kind == .browser && $0.machine.isLocal
            return !portableLocalBrowser && rejection(for: $0.machine) != nil
        } ? .cloudMachineMismatch : nil
    }

    public func rejection(for machines: [SurfaceMachineID]) -> SurfaceTransferRejection? {
        guard cloudMachine != nil else { return nil }
        return machines.isEmpty || machines.contains(where: { rejection(for: $0) != nil })
            ? .cloudMachineMismatch : nil
    }
}

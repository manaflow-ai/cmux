import Foundation

/// The pure ownership rule for a destination workspace.
///
/// A local destination accepts any source. A Cloud destination accepts only
/// resources owned by its machine, and rejects an empty or mixed selection.
public struct SurfaceOwnershipPolicy: Equatable, Sendable {
    public let cloudMachine: SurfaceMachineID?

    public init(cloudMachine: SurfaceMachineID?) {
        self.cloudMachine = cloudMachine
    }

    public func allows(source: SurfaceMachineID?) -> Bool {
        guard let cloudMachine else { return true }
        return source == cloudMachine
    }

    public func allows(resources: [SurfaceResourceID]) -> Bool {
        allows(machines: resources.map(\.machine))
    }

    public func allows(machines: [SurfaceMachineID]) -> Bool {
        guard cloudMachine != nil else { return true }
        return !machines.isEmpty && machines.allSatisfy { allows(source: $0) }
    }
}

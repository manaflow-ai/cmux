public import CmuxNextDaemon
import Foundation

/// One immutable view of the registry's admitted routes and its captured local publisher.
public nonisolated struct MachineCatalogSource: Sendable, Equatable {
    /// The local daemon's observed canonical identity.
    public let owner: ResourceID
    /// The existing local connection that owns this publication lease.
    public let writer: any MachineCatalogWriter
    /// Changes on every handshake, including a handoff within the same connection actor.
    public let epoch: Int
    /// A frame-bounded prefix of at most 256 unique remote identities, excluding self and ambiguous IDs.
    public let machines: [MachineCatalogRecord]

    /// Captures only canonical IDs and existing policy-admitted routes.
    /// No publication is possible with an unidentified local owner. Duplicate remote
    /// identities are all excluded, rather than selecting one carrier by order.
    /// - Parameters:
    ///   - owner: Observed local public identity.
    ///   - writer: Existing local carrier; never a connection factory.
    ///   - epoch: The store's handshake epoch.
    ///   - machines: Current admitted routes with owner-observed metadata.
    public init?(owner: ResourceID, writer: any MachineCatalogWriter, epoch: Int, machines: [MachineCatalogRecord]) {
        guard MachineCatalogRecord.validID(owner) else { return nil }
        self.owner = owner
        self.writer = writer
        self.epoch = epoch
        let counts = Dictionary(grouping: machines, by: \.id).mapValues(\.count)
        let encoder = JSONEncoder()
        var admitted: [MachineCatalogRecord] = []
        // Reserve more than the maximum owner/sequence/request envelope overhead.
        // This bounds the final frame as well as the individual metadata records.
        var remaining = 128 * 1024 - 512
        for machine in machines where machine.id != owner && counts[machine.id] == 1 {
            guard admitted.count < 256 else { break }
            guard let bytes = try? encoder.encode(machine).count, bytes + 1 <= remaining else { break }
            admitted.append(machine)
            remaining -= bytes + 1
        }
        self.machines = admitted
    }

    /// Equality includes carrier identity and handshake epoch, so reconnects republish unchanged data.
    /// - Parameters:
    ///   - lhs: First immutable registry view.
    ///   - rhs: Second immutable registry view.
    /// - Returns: Whether both views describe the same lease and records.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.owner == rhs.owner && lhs.writer === rhs.writer && lhs.epoch == rhs.epoch && lhs.machines == rhs.machines
    }

}

import Foundation

/// A native inventory subscription receipt, scoped to one owner and control connection.
///
/// Revisions belong to one acpmux run. Match the captured connection generation,
/// canonical owner and watch ID before accepting an invalidation; this receipt
/// neither admits a route nor grants an inventory read.
public nonisolated struct AgentInventoryWatchReceipt: Decodable, Sendable, Hashable {
    /// The canonical owner that accepted the subscription.
    public let machine: ResourceID
    /// The opaque ID of this connection's subscription generation.
    public let watchID: String
    /// The exact unsigned revision, without a floating-point conversion.
    public let revision: UInt64

    init?(machine: ResourceID, watchID: String, revision: UInt64) {
        guard MachineCatalogRecord.validID(machine), Self.validWatchID(watchID) else { return nil }
        self.machine = machine
        self.watchID = watchID
        self.revision = revision
    }

    /// Decodes a receipt directly from the native wire bytes.
    /// - Parameter decoder: The native response decoder, before generic JSON projection.
    /// - Throws: A decoding error for malformed identities or non-UInt64 revisions.
    public init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        let machine = try fields.decode(ResourceID.self, forKey: .machine)
        let watchID = try fields.decode(String.self, forKey: .watchID)
        let revision = try fields.decode(UInt64.self, forKey: .revision)
        guard let value = Self(machine: machine, watchID: watchID, revision: revision) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid inventory watch identity"))
        }
        self = value
    }

    static func validWatchID(_ value: String) -> Bool {
        value.hasPrefix("inventory_watch_") && value.utf8.count == 48
            && value.dropFirst(16).utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private enum CodingKeys: String, CodingKey {
        case machine, revision
        case watchID = "watch_id"
    }
}

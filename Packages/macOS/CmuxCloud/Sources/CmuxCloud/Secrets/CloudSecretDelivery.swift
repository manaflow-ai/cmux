import Foundation

/// The vault's ledger entry for one machine: which projects it is linked to and the
/// fingerprints last delivered to it. Names and fingerprints only, never values.
public struct CloudSecretDelivery: Hashable, Codable, Sendable {
    public let machineID: String
    /// Project keys linked to this machine, in link order. On a name clash between two
    /// project scopes the earlier link wins.
    public var projectKeys: [String]
    /// Name to the fingerprint last delivered.
    public var delivered: [String: String]
    public var deliveredAt: Date?
    /// The last sync failure, already redacted human text; cleared by a successful delivery.
    public var lastError: String?

    public init(
        machineID: String,
        projectKeys: [String] = [],
        delivered: [String: String] = [:],
        deliveredAt: Date? = nil,
        lastError: String? = nil
    ) {
        self.machineID = machineID
        self.projectKeys = projectKeys
        self.delivered = delivered
        self.deliveredAt = deliveredAt
        self.lastError = lastError
    }
}

/// Publishes the verified app's remote-route projection on its captured local connection.
///
/// The required native capability is checked before encoding, on the ready transport.
/// The owner fence prevents publication to a replacement machine. A positive increasing
/// sequence supersedes earlier snapshots; exact replay is harmless. The connection owns
/// the publication lease, which expires when that connection closes.
public nonisolated struct MachineCatalogPublishRequest: DaemonRequest {
    /// The owner's publication acknowledgement.
    public typealias Response = JSONValue
    /// The internal publication handshake; discovery still uses `machine.list/get`.
    public static let commandName: DaemonCommandName = "machine-catalog-publish"
    /// Older owners receive no publication command.
    public static let requiredCapability: String? = "machine-catalog-publish-v1"
    /// Identity fence for the captured local owner.
    public let expectedMachineID: ResourceID
    /// Positive sequence on this connection; never reused for a different snapshot.
    public let sequence: UInt64
    /// Bounded non-secret records, excluding this local owner.
    public let machines: [MachineCatalogRecord]

    /// Captures one complete projection, including an empty snapshot to withdraw routes.
    /// - Parameters:
    ///   - expectedMachineID: The local owner's observed public identity.
    ///   - sequence: A positive, monotonically increasing sequence for this connection.
    ///   - machines: Up to 256 admitted existing remote routes.
    public init(expectedMachineID: ResourceID, sequence: UInt64, machines: [MachineCatalogRecord]) {
        self.expectedMachineID = expectedMachineID
        self.sequence = sequence
        self.machines = machines
    }

    enum CodingKeys: String, CodingKey {
        case expectedMachineID = "expected_machine_id", sequence, machines
    }
}

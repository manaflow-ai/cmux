/// A registry refresh result carrying the canonical owner that produced it.
///
/// Installation and sign-in observations remain cached. The returned inventory
/// can contain older latest-version timestamps when a registry was unavailable.
public nonisolated struct AgentInventoryRefreshReceipt: Decodable, Sendable, Equatable {
    /// The canonical machine that accepted the refresh condition.
    public let machine: ResourceID
    /// The same sanitized inventory shape used for ordinary cache reads.
    public let inventory: AcpmuxHarnessInventory

    private enum CodingKeys: String, CodingKey { case machine }

    /// Decodes the owner and inventory directly from the native response bytes.
    /// - Parameter decoder: The result object, before generic JSON conversion.
    /// - Throws: A decoding error for a missing/noncanonical owner or invalid inventory.
    public init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        machine = try fields.decode(ResourceID.self, forKey: .machine)
        guard MachineCatalogRecord.validID(machine) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                debugDescription: "Invalid inventory refresh owner"))
        }
        inventory = try AcpmuxHarnessInventory(from: decoder)
    }
}

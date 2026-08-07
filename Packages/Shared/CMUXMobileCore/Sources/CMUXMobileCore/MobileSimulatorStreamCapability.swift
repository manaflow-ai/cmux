public struct MobileSimulatorStreamCapability: Sendable {
    public static let current = MobileSimulatorStreamCapability()

    public let identifier: String
    public let inputIdentifier: String
    public let ownershipIdentifier: String

    public init(
        identifier: String = "simulator.stream.v1",
        inputIdentifier: String = "simulator.input.v1",
        ownershipIdentifier: String = "simulator.ownership.v1"
    ) {
        self.identifier = identifier
        self.inputIdentifier = inputIdentifier
        self.ownershipIdentifier = ownershipIdentifier
    }
}

public struct MobileSimulatorStreamCapability: Sendable {
    public static let current = MobileSimulatorStreamCapability()

    public let identifier: String
    public let inputIdentifier: String
    public let ownershipIdentifier: String
    /// The Mac re-emits `simulator.state` on a fixed cadence while a stream
    /// session is active, so clients can treat event silence as staleness
    /// without misreading a static Simulator screen as a dead stream.
    public let keepaliveIdentifier: String

    public init(
        identifier: String = "simulator.stream.v1",
        inputIdentifier: String = "simulator.input.v1",
        ownershipIdentifier: String = "simulator.ownership.v1",
        keepaliveIdentifier: String = "simulator.keepalive.v1"
    ) {
        self.identifier = identifier
        self.inputIdentifier = inputIdentifier
        self.ownershipIdentifier = ownershipIdentifier
        self.keepaliveIdentifier = keepaliveIdentifier
    }
}

public struct MobileSimulatorStreamCapability: Sendable {
    public static let current = MobileSimulatorStreamCapability()

    public let identifier: String
    public let inputIdentifier: String
    public let ownershipIdentifier: String
    /// The Mac re-emits `simulator.state` on a fixed cadence while a stream
    /// session is active, so clients can treat event silence as staleness
    /// without misreading a static Simulator screen as a dead stream.
    public let keepaliveIdentifier: String
    /// Simulator streaming v2: HEVC/H.264 video plus input over a dedicated
    /// `simulatorStream` iroh lane. Phones that see this skip the v1
    /// image-event stream entirely. Wire contract:
    /// `CmuxSimulatorStreamKit.SimStreamProtocol` (same literal, duplicated
    /// so this base DTO package does not link VideoToolbox).
    public let streamV2Identifier: String
    /// The host serves `mobile.simulator.devices.list` and
    /// `mobile.simulator.device.select`, so phones can switch which
    /// simulator a panel streams.
    public let devicesIdentifier: String

    public init(
        identifier: String = "simulator.stream.v1",
        inputIdentifier: String = "simulator.input.v1",
        ownershipIdentifier: String = "simulator.ownership.v1",
        keepaliveIdentifier: String = "simulator.keepalive.v1",
        streamV2Identifier: String = "simulator.stream.v2",
        devicesIdentifier: String = "simulator.devices.v1"
    ) {
        self.identifier = identifier
        self.inputIdentifier = inputIdentifier
        self.ownershipIdentifier = ownershipIdentifier
        self.keepaliveIdentifier = keepaliveIdentifier
        self.streamV2Identifier = streamV2Identifier
        self.devicesIdentifier = devicesIdentifier
    }
}

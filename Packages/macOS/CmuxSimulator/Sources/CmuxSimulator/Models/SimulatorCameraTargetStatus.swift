/// Liveness and shared-feed attachment for one injected Simulator app.
public struct SimulatorCameraTargetStatus: Codable, Equatable, Sendable {
    public let bundleIdentifier: String
    public let processIdentifier: Int32?
    public let isAlive: Bool
    public let isAttached: Bool

    public init(
        bundleIdentifier: String,
        processIdentifier: Int32?,
        isAlive: Bool,
        isAttached: Bool
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.processIdentifier = processIdentifier
        self.isAlive = isAlive
        self.isAttached = isAttached
    }
}

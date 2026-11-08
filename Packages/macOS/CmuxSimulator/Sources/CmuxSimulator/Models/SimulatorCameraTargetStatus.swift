/// Liveness and shared-feed attachment for one injected Simulator app.
public struct SimulatorCameraTargetStatus: Codable, Equatable, Sendable {
    /// Bundle identifier of the injected application.
    public let bundleIdentifier: String
    /// Current application process identifier, when running.
    public let processIdentifier: Int32?
    /// Whether the target process is currently alive.
    public let isAlive: Bool
    /// Whether the target is attached to the shared camera feed.
    public let isAttached: Bool

    /// Creates one camera target liveness snapshot.
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

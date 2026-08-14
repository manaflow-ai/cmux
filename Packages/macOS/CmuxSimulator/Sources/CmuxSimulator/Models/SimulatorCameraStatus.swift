/// A correlated snapshot of the contained camera adapter.
public struct SimulatorCameraStatus: Codable, Equatable, Sendable {
    /// The active source configuration.
    public let configuration: SimulatorCameraConfiguration
    /// The source-independent mirror mode.
    public let mirrorMode: SimulatorCameraMirrorMode
    /// Bundle identifiers currently carrying the injected adapter.
    public let injectedBundleIdentifiers: [String]
    /// The currently selected injection target.
    public let targetBundleIdentifier: String?
    /// PID written by the injected dylib into the shared control region.
    public let targetProcessIdentifier: Int32?
    /// Whether the target dylib's heartbeat is fresh.
    public let targetIsAlive: Bool
    /// Whether the live target is attached to this worker's surface ring.
    public let targetIsAttached: Bool
    /// Every configured target and its current process/feed state.
    public let targets: [SimulatorCameraTargetStatus]
    /// Host capture devices available to the worker.
    public let hostCameras: [SimulatorHostCameraDevice]

    /// Creates a camera status snapshot.
    public init(
        configuration: SimulatorCameraConfiguration,
        mirrorMode: SimulatorCameraMirrorMode,
        injectedBundleIdentifiers: [String],
        targetBundleIdentifier: String? = nil,
        targetProcessIdentifier: Int32? = nil,
        targetIsAlive: Bool = false,
        targetIsAttached: Bool = false,
        targets: [SimulatorCameraTargetStatus] = [],
        hostCameras: [SimulatorHostCameraDevice]
    ) {
        self.configuration = configuration
        self.mirrorMode = mirrorMode
        self.injectedBundleIdentifiers = injectedBundleIdentifiers
        self.targetBundleIdentifier = targetBundleIdentifier
        self.targetProcessIdentifier = targetProcessIdentifier
        self.targetIsAlive = targetIsAlive
        self.targetIsAttached = targetIsAttached
        self.targets = targets
        self.hostCameras = hostCameras
    }
}

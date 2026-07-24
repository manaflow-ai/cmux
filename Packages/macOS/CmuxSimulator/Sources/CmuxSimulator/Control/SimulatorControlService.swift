import CmuxFoundation
import Foundation

/// A typed, injectable actor for supported `xcrun simctl` operations.
///
/// The service owns only one-shot commands. Long-running video and log
/// operations return ``SimulatorCommandDescriptor`` values so their caller can
/// send `SIGINT` and wait for clean finalization rather than relying on a
/// capture timeout.
public actor SimulatorControlService: SimulatorControlling {
    let commands: any CommandRunning
    let boundedCommands: any SimulatorBoundedCommandRunning
    let commandTimeout: TimeInterval
    let bootTimeout: TimeInterval
    let fileManager: FileManager
    let currentDirectoryURL: URL
    let makeUUID: @Sendable () -> UUID
    let now: @Sendable () -> Date
    let routeSleep: @Sendable (Duration) async throws -> Void
    let locationOwnershipRegistry: SimulatorLocationOwnershipRegistry
    let cameraCleanupOwnershipStore: SimulatorCrossProcessOwnershipStore
    let fractionalDateFormatter: ISO8601DateFormatter
    let internetDateFormatter: ISO8601DateFormatter
    let mutationGate = SimulatorMutationGate()
    var activeLocationRoutes: [String: ActiveLocationRoute] = [:]
    var locationRouteInitialCoordinates: [String: SimulatorLocationCoordinate] = [:]
    var locationLifecycleTasks: [String: Task<Void, Never>] = [:]
    var locationRouteTokens: [String: UUID] = [:]

    /// Creates a Simulator control service.
    /// - Parameters:
    ///   - commands: Injected process runner. Tests can provide a fake.
    ///   - commandTimeout: Deadline for ordinary one-shot operations.
    ///   - bootTimeout: Deadline for CoreSimulator boot completion.
    ///   - fileManager: Filesystem dependency used for bounded staging files.
    ///   - currentDirectoryURL: Working directory passed to child commands.
    ///   - makeUUID: Identifier source used to name private staging files.
    ///   - now: Injected wall clock used to estimate a paused route position.
    ///   - cameraCleanupOwnershipScope: Shared camera cleanup ownership for this service graph.
    ///   - routeSleep: Injected monotonic delay used to complete or restart routes.
    public init(
        commands: any CommandRunning = CommandRunner(),
        commandTimeout: TimeInterval = 30,
        bootTimeout: TimeInterval = 180,
        fileManager: FileManager = FileManager(),
        currentDirectoryURL: URL = URL(fileURLWithPath: ".").standardizedFileURL,
        makeUUID: @escaping @Sendable () -> UUID = UUID.init,
        now: @escaping @Sendable () -> Date = Date.init,
        locationOwnershipScope: SimulatorLocationOwnershipScope = SimulatorLocationOwnershipScope(),
        cameraCleanupOwnershipScope: SimulatorCameraCleanupOwnershipScope =
            SimulatorCameraCleanupOwnershipScope(),
        routeSleep: @escaping @Sendable (Duration) async throws -> Void = {
            try await ContinuousClock().sleep(for: $0)
        }
    ) {
        self.commands = commands
        if let bounded = commands as? any SimulatorBoundedCommandRunning {
            boundedCommands = bounded
        } else if commands is CommandRunner {
            boundedCommands = SimulatorBoundedCommandRunner()
        } else {
            boundedCommands = SimulatorLegacyBoundedCommandRunner(commands: commands)
        }
        self.commandTimeout = commandTimeout
        self.bootTimeout = bootTimeout
        self.fileManager = fileManager
        self.currentDirectoryURL = currentDirectoryURL
        self.makeUUID = makeUUID
        self.now = now
        self.locationOwnershipRegistry = locationOwnershipScope.registry
        self.cameraCleanupOwnershipStore = cameraCleanupOwnershipScope.ownershipStore
        self.routeSleep = routeSleep
        let fractionalDateFormatter = ISO8601DateFormatter()
        fractionalDateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.fractionalDateFormatter = fractionalDateFormatter
        self.internetDateFormatter = ISO8601DateFormatter()
    }

    deinit {
        for task in locationLifecycleTasks.values { task.cancel() }
    }

    /// Discovers every installed device and maps its runtime and device family.
}

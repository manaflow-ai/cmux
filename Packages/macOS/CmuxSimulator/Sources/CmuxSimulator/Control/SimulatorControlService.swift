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
    let now: @Sendable () -> Date
    let routeSleep: @Sendable (Duration) async throws -> Void
    var activeLocationRoutes: [String: ActiveLocationRoute] = [:]
    var locationRouteInitialCoordinates: [String: SimulatorLocationCoordinate] = [:]
    var locationLifecycleTasks: [String: Task<Void, Never>] = [:]
    var locationRouteTokens: [String: UUID] = [:]

    /// Creates a Simulator control service.
    /// - Parameters:
    ///   - commands: Injected process runner. Tests can provide a fake.
    ///   - commandTimeout: Deadline for ordinary one-shot operations.
    ///   - bootTimeout: Deadline for CoreSimulator boot completion.
    ///   - now: Injected wall clock used to estimate a paused route position.
    ///   - routeSleep: Injected monotonic delay used to complete or restart routes.
    public init(
        commands: any CommandRunning = CommandRunner(),
        commandTimeout: TimeInterval = 30,
        bootTimeout: TimeInterval = 180,
        now: @escaping @Sendable () -> Date = Date.init,
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
        self.now = now
        self.routeSleep = routeSleep
    }

    deinit {
        for task in locationLifecycleTasks.values { task.cancel() }
    }

    /// Discovers every installed device and maps its runtime and device family.
}

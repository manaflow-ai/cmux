/// Stores the app-side result of provisioning a task workspace.
public struct FleetProvisionOutcome: Equatable, Sendable {
    /// The cmux workspace identifier.
    public var workspaceID: String

    /// The cmux surface identifier that receives agent input.
    public var surfaceID: String

    /// The task working directory path.
    public var directoryPath: String

    /// The git branch assigned to the task, when known.
    public var branch: String?

    /// Whether the workspace directory was newly created.
    public var isBrandNew: Bool

    /// Creates a provisioning outcome.
    /// - Parameters:
    ///   - workspaceID: The cmux workspace identifier.
    ///   - surfaceID: The cmux surface identifier that receives agent input.
    ///   - directoryPath: The task working directory path.
    ///   - branch: The git branch assigned to the task, when known.
    ///   - isBrandNew: Whether the workspace directory was newly created.
    public init(
        workspaceID: String,
        surfaceID: String,
        directoryPath: String,
        branch: String?,
        isBrandNew: Bool
    ) {
        self.workspaceID = workspaceID
        self.surfaceID = surfaceID
        self.directoryPath = directoryPath
        self.branch = branch
        self.isBrandNew = isBrandNew
    }
}

/// Describes an app-side actuation failure.
public struct FleetActuationError: Error, Equatable, Sendable {
    /// The human-readable failure message.
    public var message: String

    /// Creates an actuation failure.
    /// - Parameter message: The human-readable failure message.
    public init(message: String) {
        self.message = message
    }
}

/// Performs Fleet's app-side imperative mutations.
@MainActor
public protocol FleetActuating: AnyObject {
    /// Provisions a workspace for a task.
    func provisionWorkspace(task: FleetTask, fleet: FleetConfig) async -> Result<FleetProvisionOutcome, FleetActuationError>

    /// Sends text to an existing agent surface.
    func sendAgentCommand(workspaceID: String, surfaceID: String, text: String) -> Bool

    /// Terminates the current agent process or sends interrupt input.
    func killAgent(workspaceID: String, surfaceID: String, pid: Int32?)

    /// Closes a task workspace without deleting its directory.
    func closeWorkspace(workspaceID: String)

    /// Posts a Fleet notification.
    func postNotification(fleet: FleetConfig, task: FleetTask, kind: FleetNotificationKind)
}

/// Reads app-side Fleet world state.
@MainActor
public protocol FleetWorldReading: AnyObject {
    /// Returns whether a workspace still exists.
    func workspaceExists(workspaceID: String) -> Bool

    /// Reads the pull-request status attached to a workspace.
    func pullRequestStatus(workspaceID: String, directoryPath: String?, branch: String?) -> FleetPullRequestStatus?

    /// Returns whether a task surface is at an idle shell prompt.
    func isShellPromptIdle(workspaceID: String, surfaceID: String) -> Bool?
}

/// Schedules cancellable Fleet timers.
@MainActor
public protocol FleetTimerScheduling: AnyObject {
    /// Schedules a one-shot timer.
    func schedule(key: String, delayMS: Int, onFire: @escaping @MainActor () -> Void)

    /// Cancels a timer by key.
    func cancel(key: String)

    /// Cancels all timers.
    func cancelAll()
}

/// Watches process exits for supervised agent processes.
@MainActor
public protocol FleetProcessWatching: AnyObject {
    /// Starts watching a process exit.
    func watchExit(pid: Int32, onExit: @escaping @MainActor () -> Void)

    /// Cancels a process watcher.
    func cancel(pid: Int32)
}

/// Persists and restores Fleet engine snapshots.
@MainActor
public protocol FleetPersisting: AnyObject {
    /// Saves a Fleet engine snapshot.
    func save(_ state: FleetPersistedState)

    /// Loads the last Fleet engine snapshot.
    func load() -> FleetPersistedState?
}

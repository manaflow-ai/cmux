/// The Fleet-domain slice of the control-command seam.
///
/// PR 2 of the #7361 chain defines only the socket package contract and the app
/// target's unavailable stubs. PR 3 replaces the app stubs with the FleetEngine
/// bridge while keeping this protocol as the coordinator boundary.
@MainActor
public protocol ControlFleetContext: AnyObject {
    /// Lists every visible Fleet.
    ///
    /// - Returns: The Fleet snapshots in app-defined order.
    func controlFleetList() -> [ControlFleetSnapshot]

    /// Reads Fleet engine status, optionally scoped to one Fleet.
    ///
    /// - Parameter fleetID: The optional Fleet identifier.
    /// - Returns: The status resolution.
    func controlFleetStatus(fleetID: String?) -> ControlFleetStatusResolution

    /// Creates a Fleet.
    ///
    /// - Parameter inputs: The validated creation inputs.
    /// - Returns: The creation resolution.
    func controlFleetCreate(inputs: ControlFleetCreateInputs) -> ControlFleetCreateResolution

    /// Starts a Fleet.
    ///
    /// - Parameter fleetID: The Fleet identifier.
    /// - Returns: The lifecycle resolution.
    func controlFleetStart(fleetID: String) -> ControlFleetLifecycleResolution

    /// Stops a Fleet.
    ///
    /// - Parameter fleetID: The Fleet identifier.
    /// - Returns: The lifecycle resolution.
    func controlFleetStop(fleetID: String) -> ControlFleetLifecycleResolution

    /// Adds a task to a Fleet.
    ///
    /// - Parameter inputs: The validated task creation inputs.
    /// - Returns: The task-add resolution.
    func controlFleetTaskAdd(inputs: ControlFleetTaskAddInputs) -> ControlFleetTaskAddResolution

    /// Lists Fleet tasks, optionally filtered by Fleet and state.
    ///
    /// - Parameters:
    ///   - fleetID: The optional Fleet identifier.
    ///   - state: The optional task-state filter.
    /// - Returns: The task-list resolution.
    func controlFleetTaskList(
        fleetID: String?,
        state: ControlFleetTaskStateName?
    ) -> ControlFleetTaskListResolution

    /// Retries a Fleet task.
    ///
    /// - Parameter taskID: The task identifier.
    /// - Returns: The task-action resolution.
    func controlFleetTaskRetry(taskID: String) -> ControlFleetTaskActionResolution

    /// Cancels a Fleet task.
    ///
    /// - Parameter taskID: The task identifier.
    /// - Returns: The task-action resolution.
    func controlFleetTaskCancel(taskID: String) -> ControlFleetTaskActionResolution

    /// Opens the workspace associated with a Fleet task.
    ///
    /// - Parameter taskID: The task identifier.
    /// - Returns: The task-open resolution.
    func controlFleetTaskOpen(taskID: String) -> ControlFleetTaskOpenResolution
}

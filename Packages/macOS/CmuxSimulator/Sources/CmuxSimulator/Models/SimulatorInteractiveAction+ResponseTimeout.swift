extension SimulatorInteractiveAction {
    /// Deadline that covers the action's declared pacing plus worker overhead.
    public var responseTimeout: Duration {
        simulatorInteractiveResponseTimeout(for: self)
    }
}

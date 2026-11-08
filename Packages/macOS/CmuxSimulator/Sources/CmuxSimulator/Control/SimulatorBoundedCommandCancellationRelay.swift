actor SimulatorBoundedCommandCancellationRelay {
    private var state: SimulatorBoundedCommandRunState?
    private var cancelled = false

    var isCancelled: Bool {
        cancelled
    }

    var installedState: SimulatorBoundedCommandRunState? {
        state
    }

    func install(_ state: SimulatorBoundedCommandRunState) {
        self.state = state
    }

    func cancel(
        with result: SimulatorBoundedCommandResult
    ) async -> SimulatorProcessGroupProcess? {
        guard !cancelled else { return nil }
        cancelled = true
        return await state?.requestTermination(result)
    }
}

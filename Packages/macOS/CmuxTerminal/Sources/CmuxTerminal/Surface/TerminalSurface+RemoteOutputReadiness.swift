extension TerminalSurface {
    /// Waits for already submitted remote output to reach the native parser.
    ///
    /// This suspends without blocking the main actor or closing the output lane.
    /// Callers must still wait for a renderer frame after this fence completes.
    /// - Returns: Whether the runtime generation remained live and all buffered
    ///   output had been submitted. A missing or replaced runtime returns false.
    @MainActor
    public func waitForRemoteOutput() async -> Bool {
        guard surface != nil, pendingRemoteOutput.isEmpty else { return false }
        let generation = remoteOutputLaneGeneration
        await remoteOutputLane.waitForSubmittedOutput()
        return generation == remoteOutputLaneGeneration && surface != nil && pendingRemoteOutput.isEmpty
    }
}

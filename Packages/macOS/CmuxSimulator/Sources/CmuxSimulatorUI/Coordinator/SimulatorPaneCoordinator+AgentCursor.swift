import CmuxSimulator

extension SimulatorPaneCoordinator {
    /// Starts a pane-owned cursor presentation for one programmatic pointer action.
    ///
    /// The coordinator belongs to one `SimulatorPanel`, which belongs to one
    /// workspace. No process-global cursor registry is used.
    func beginAgentCursorPresentation(_ plan: SimulatorAgentCursorPlan) -> UInt64 {
        agentCursorGeneration &+= 1
        let generation = agentCursorGeneration
        agentCursorPresentation = SimulatorAgentCursorPresentation(
            generation: generation,
            origin: plan.origin,
            destination: plan.destination,
            durationMilliseconds: plan.durationMilliseconds,
            phase: plan.beginsTouch ? .pressed : .clicked
        )
        return generation
    }

    /// Completes the current pointer presentation without overriding newer work.
    func completeAgentCursorPresentation(
        _ plan: SimulatorAgentCursorPlan,
        token: UInt64
    ) {
        guard agentCursorPresentation?.generation == token,
              let completionPhase = plan.completionPhase else {
            return
        }
        agentCursorGeneration &+= 1
        agentCursorPresentation = SimulatorAgentCursorPresentation(
            generation: agentCursorGeneration,
            origin: plan.destination,
            destination: plan.destination,
            durationMilliseconds: 0,
            phase: completionPhase
        )
    }

    /// Releases a failed pointer presentation without a success pulse.
    func cancelAgentCursorPresentation(
        _ plan: SimulatorAgentCursorPlan,
        token: UInt64
    ) {
        guard agentCursorPresentation?.generation == token else { return }
        agentCursorGeneration &+= 1
        agentCursorPresentation = SimulatorAgentCursorPresentation(
            generation: agentCursorGeneration,
            origin: plan.destination,
            destination: plan.destination,
            durationMilliseconds: 0,
            phase: .cancelled
        )
    }

    /// Dismisses a completed cursor only if no newer action replaced it.
    func dismissAgentCursorPresentation(generation: UInt64) {
        guard agentCursorPresentation?.generation == generation else { return }
        agentCursorPresentation = nil
    }

    /// Clears cursor state during device or pane lifecycle teardown.
    func resetAgentCursorPresentation() {
        agentCursorGeneration &+= 1
        agentCursorPresentation = nil
    }
}

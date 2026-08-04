import CmuxSimulator
import Foundation

extension SimulatorPaneCoordinator {
    /// Starts a pane-owned cursor presentation for one programmatic pointer action.
    ///
    /// The coordinator belongs to one `SimulatorPanel`, which belongs to one
    /// workspace. No process-global cursor registry is used.
    func beginAgentCursorPresentation(
        _ plan: SimulatorAgentCursorPlan
    ) async throws -> UInt64 {
        let currentPosition = agentCursorPresentation?.destination ?? plan.origin
        let travelDurationMilliseconds = agentCursorTravelDurationMilliseconds(
            from: currentPosition,
            to: plan.origin
        )
        if travelDurationMilliseconds > 0 {
            agentCursorGeneration &+= 1
            let travelGeneration = agentCursorGeneration
            agentCursorPresentation = SimulatorAgentCursorPresentation(
                generation: travelGeneration,
                origin: currentPosition,
                destination: plan.origin,
                durationMilliseconds: travelDurationMilliseconds,
                phase: .resting,
                clickPhaseDelayMilliseconds: 0
            )
            try await agentCursorSleeper.sleep(
                for: .milliseconds(travelDurationMilliseconds)
            )
            try Task.checkCancellation()
            guard agentCursorPresentation?.generation == travelGeneration,
                  !closed else {
                throw CancellationError()
            }
        }

        try Task.checkCancellation()
        agentCursorGeneration &+= 1
        let generation = agentCursorGeneration
        let phase: SimulatorAgentCursorPhase = plan.beginsTouch ? .pressed : .clicked
        agentCursorPresentation = SimulatorAgentCursorPresentation(
            generation: generation,
            origin: plan.origin,
            destination: plan.destination,
            durationMilliseconds: plan.durationMilliseconds,
            phase: phase,
            clickPhaseDelayMilliseconds: 0
        )
        return generation
    }

    private func agentCursorTravelDurationMilliseconds(
        from origin: SimulatorPoint,
        to destination: SimulatorPoint
    ) -> Int {
        let distance = hypot(
            destination.x - origin.x,
            destination.y - origin.y
        )
        guard distance > 0.002 else { return 0 }
        return Int(140 + min(distance, 1) * 260)
    }

    /// Completes the current pointer presentation without overriding newer work.
    func completeAgentCursorPresentation(
        _ plan: SimulatorAgentCursorPlan,
        token: UInt64
    ) {
        guard agentCursorPresentation?.generation == token,
              let completionPhase = plan.completionPhase,
              let presentation = agentCursorPresentation else {
            return
        }
        agentCursorPresentation = SimulatorAgentCursorPresentation(
            generation: presentation.generation,
            origin: presentation.origin,
            destination: presentation.destination,
            durationMilliseconds: presentation.durationMilliseconds,
            phase: completionPhase,
            clickPhaseDelayMilliseconds: completionPhase == .clicked
                ? max(
                    0,
                    presentation.durationMilliseconds - plan.durationMilliseconds
                )
                : 0
        )
    }

    /// Releases a failed pointer presentation without a success pulse.
    func cancelAgentCursorPresentation(
        _ plan: SimulatorAgentCursorPlan,
        token: UInt64
    ) {
        guard agentCursorPresentation?.generation == token,
              let presentation = agentCursorPresentation else { return }
        agentCursorPresentation = SimulatorAgentCursorPresentation(
            generation: presentation.generation,
            origin: presentation.origin,
            destination: presentation.destination,
            durationMilliseconds: presentation.durationMilliseconds,
            phase: .cancelled,
            clickPhaseDelayMilliseconds: 0
        )
    }

    /// Creates the workspace cursor once its first live display arrives.
    func ensureAgentCursorPresentation() {
        guard agentCursorPresentation == nil else { return }
        agentCursorGeneration &+= 1
        let center = SimulatorPoint(x: 0.5, y: 0.5)
        agentCursorPresentation = SimulatorAgentCursorPresentation(
            generation: agentCursorGeneration,
            origin: center,
            destination: center,
            durationMilliseconds: 0,
            phase: .resting,
            clickPhaseDelayMilliseconds: 0
        )
    }

    /// Clears device-bound cursor state and invalidates in-flight presentations.
    func resetAgentCursorPresentation() {
        agentCursorGeneration &+= 1
        agentCursorPresentation = nil
    }

}

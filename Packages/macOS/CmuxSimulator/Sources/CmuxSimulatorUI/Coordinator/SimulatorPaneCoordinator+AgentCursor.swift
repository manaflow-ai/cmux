import CmuxSimulator
import Foundation

extension SimulatorPaneCoordinator {
    /// Starts a pane-owned cursor presentation for one programmatic pointer action.
    ///
    /// The coordinator belongs to one `SimulatorPanel`, which belongs to one
    /// workspace. No process-global cursor registry is used.
    func beginAgentCursorPresentation(_ plan: SimulatorAgentCursorPlan) -> UInt64 {
        agentCursorGeneration &+= 1
        let generation = agentCursorGeneration
        let origin = agentCursorPresentation?.destination ?? plan.origin
        let distance = hypot(
            plan.destination.x - origin.x,
            plan.destination.y - origin.y
        )
        let durationMilliseconds: Int
        if distance > 0.002 {
            let travelMilliseconds = Int(140 + min(distance, 1) * 260)
            durationMilliseconds = max(plan.durationMilliseconds, travelMilliseconds)
        } else {
            durationMilliseconds = plan.durationMilliseconds
        }
        agentCursorPresentation = SimulatorAgentCursorPresentation(
            generation: generation,
            origin: origin,
            destination: plan.destination,
            durationMilliseconds: durationMilliseconds,
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
              let completionPhase = plan.completionPhase,
              let presentation = agentCursorPresentation else {
            return
        }
        agentCursorPresentation = SimulatorAgentCursorPresentation(
            generation: presentation.generation,
            origin: presentation.origin,
            destination: presentation.destination,
            durationMilliseconds: presentation.durationMilliseconds,
            phase: completionPhase
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
            phase: .cancelled
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
            phase: .resting
        )
    }

}

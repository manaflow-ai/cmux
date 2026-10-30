public import CmuxNextActions
import CmuxNextDesign
import Observation

extension ActionRegistry {
    /// Publishes Debug Settings' Side sessions (/btw) as the live action context fact.
    /// Observation is re-armed after every toggle change; Release and RC stores remain inert.
    public func publishSideSessions() {
        let on = withObservationTracking {
            _ = TunableStore.shared.revision
            return AgentPaneTunables.sideSessions.value
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.publishSideSessions() }
        }
        var next = context
        if on { next.insert(.sideSessions) } else { next.remove(.sideSessions) }
        if next != context { context = next }
    }
}

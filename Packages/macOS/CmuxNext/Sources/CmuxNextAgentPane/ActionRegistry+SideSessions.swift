public import CmuxNextActions
import CmuxNextDesign
import Observation

extension ActionRegistry {
    /// Publishes Debug Settings' Side sessions (/btw) (``AgentPaneTunables/sideSessions``) as the
    /// ``ActionContext/sideSessions`` fact, now and on every change of the toggle, so Ask a Side
    /// Question… is offered only while it is on, the same toggle the page's `/btw` reads. Observes the
    /// toggle, re-armed after each change; nothing polls. In Release and RC the store is inert, so the
    /// fact stays off.
    public func publishSideSessions() {
        // The store's revision too: before the store is active (launch) the toggle's read observes nothing.
        let on = withObservationTracking { _ = TunableStore.shared.revision; return AgentPaneTunables.sideSessions.value } onChange: { [weak self] in
            // task-owner: one hop per store change, re-arms itself; ends with the registry
            Task { @MainActor [weak self] in self?.publishSideSessions() }
        }
        var next = context
        if on { next.insert(.sideSessions) } else { next.remove(.sideSessions) }
        if next != context { context = next }
    }
}

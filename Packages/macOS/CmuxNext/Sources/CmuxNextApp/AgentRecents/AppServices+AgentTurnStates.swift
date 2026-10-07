import CmuxNextBridge
import CmuxNextDaemon

/// The working and needs-input indicators of agent chat tabs read the local
/// acpmux turn states (WORKING-AND-LOADING-INDICATORS). The first window
/// starts the shared watch; later windows reuse it.
extension AppServices {
    func startAgentTurnStates() {
        let store = AgentTurnStateStore.shared
        if store.localHost == nil, let id = try? cloud.localDeviceID() {
            store.localHost = AgentSessionRef.host(installID: id)
        }
        agentRecents?.startTurnStates()
    }
}

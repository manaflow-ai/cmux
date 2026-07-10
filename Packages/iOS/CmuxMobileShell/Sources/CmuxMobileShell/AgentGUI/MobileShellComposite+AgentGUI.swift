import CmuxAgentSync
import CmuxMobileRPC
import Foundation

@MainActor
extension MobileShellComposite {
    func installAgentGUIEngine(
        client: MobileCoreRPCClient,
        generation: UUID
    ) {
        guard agentGUIConnectionGeneration != generation || agentSyncEngine == nil else { return }

        agentGUIConnectionEventRelay?.yield(.reset)
        agentSyncEngine?.stop()

        let relay = AgentGUIConnectionEventRelay()
        let transport = AgentGUISyncTransportRPC(
            client: client,
            streamID: "ios-agent-gui-events-\(clientID)-\(generation.uuidString)",
            connectionEvents: relay.events
        )
        let engine = AgentSyncEngine(transport: transport)
        agentGUIConnectionGeneration = generation
        agentGUIConnectionEventRelay = relay
        agentSyncEngine = engine
        engine.start()
    }

    func clearAgentGUIEngine(reason: String) {
        agentGUIConnectionEventRelay?.yield(.down(reason: reason))
        agentSyncEngine?.stop()
        agentSyncEngine = nil
        agentGUIConnectionGeneration = nil
        agentGUIConnectionEventRelay = nil
    }

    func resetAgentGUIEngine() {
        agentGUIConnectionEventRelay?.yield(.reset)
        agentSyncEngine?.stop()
        agentSyncEngine = nil
        agentGUIConnectionGeneration = nil
        agentGUIConnectionEventRelay = nil
    }

    func noteAgentGUIConnectionHealthy() {
        agentGUIConnectionEventRelay?.yield(.up)
    }

    func noteAgentGUIConnectionReconnecting() {
        agentGUIConnectionEventRelay?.yield(.down(reason: "reconnecting"))
    }

    func noteAgentGUIConnectionUnavailable() {
        agentGUIConnectionEventRelay?.yield(.down(reason: "unavailable"))
    }
}

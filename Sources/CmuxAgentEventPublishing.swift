import Foundation

extension CmuxEventBus {
    func publishAgentStateChanged(
        workspaceID: UUID,
        surfaceID: UUID,
        paneID: UUID?,
        record: AgentLifecycleRecord,
        state: AgentLifecyclePublicState,
        previousState: AgentLifecyclePublicState?
    ) {
        publish(
            name: "agent.state.changed",
            category: "agent",
            source: "agent.lifecycle",
            workspaceId: workspaceID.uuidString,
            surfaceId: surfaceID.uuidString,
            paneId: paneID?.uuidString,
            payload: [
                "agent": record.agent,
                "state": state.rawValue,
                "previous_state": previousState?.rawValue ?? NSNull(),
                "session_id": record.sessionID ?? NSNull(),
                "revision": NSNumber(value: record.revision),
            ]
        )
    }
}

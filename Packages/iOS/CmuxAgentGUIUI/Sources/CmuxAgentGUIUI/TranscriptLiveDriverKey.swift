import CmuxAgentReplica
import CmuxAgentSync

struct TranscriptLiveDriverKey: Equatable {
    let engineID: ObjectIdentifier
    let sessionID: AgentSessionID

    init(engine: AgentSyncEngine, sessionID: AgentSessionID) {
        self.engineID = ObjectIdentifier(engine)
        self.sessionID = sessionID
    }
}

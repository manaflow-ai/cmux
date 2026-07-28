import Foundation

struct AgentLifecycleRecord: Sendable, Equatable {
    let agent: String
    var state: AgentHibernationLifecycleState
    var sessionID: String?
    let revision: UInt64

    var publicState: AgentLifecyclePublicState {
        AgentLifecyclePublicState(state)
    }

    func identifiesSameOccupant(as other: AgentLifecycleRecord) -> Bool {
        guard agent == other.agent else { return false }
        if let sessionID, let otherSessionID = other.sessionID {
            return sessionID == otherSessionID
        }
        return revision == other.revision
    }
}

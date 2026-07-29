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
        switch (sessionID, other.sessionID) {
        case let (sessionID?, otherSessionID?):
            return sessionID == otherSessionID
        case (nil, nil):
            return revision == other.revision
        default:
            return false
        }
    }
}

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
        if revision == other.revision {
            if let sessionID, let otherSessionID = other.sessionID {
                return sessionID == otherSessionID
            }
            return true
        }
        switch (sessionID, other.sessionID) {
        case let (sessionID?, otherSessionID?):
            return sessionID == otherSessionID
        case (nil, nil), (nil, _?), (_?, nil):
            return false
        }
    }
}

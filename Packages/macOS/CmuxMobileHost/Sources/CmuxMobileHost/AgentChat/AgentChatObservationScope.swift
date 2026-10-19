public import Foundation

public enum AgentChatObservationScope: Equatable, Sendable {
    case all
    case surfaces(Set<UUID>)

    public init(surfaceIDs: Set<UUID>?) {
        if let surfaceIDs {
            self = .surfaces(surfaceIDs)
        } else {
            self = .all
        }
    }

    public var surfaceIDs: Set<UUID>? {
        switch self {
        case .all:
            return nil
        case .surfaces(let ids):
            return ids
        }
    }

    public func covers(_ requested: AgentChatObservationScope) -> Bool {
        switch (self, requested) {
        case (.all, _):
            return true
        case (.surfaces, .all):
            return false
        case (.surfaces(let current), .surfaces(let requestedIDs)):
            return current.isSuperset(of: requestedIDs)
        }
    }
}

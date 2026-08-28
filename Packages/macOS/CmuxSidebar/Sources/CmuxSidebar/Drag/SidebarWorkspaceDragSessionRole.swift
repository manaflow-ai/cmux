import Foundation

/// A sidebar presentation's ownership role in one workspace drag session.
enum SidebarWorkspaceDragSessionRole {
    case source(UUID)
    case mirror(UUID)

    var sessionId: UUID {
        switch self {
        case .source(let id), .mirror(let id): id
        }
    }
}

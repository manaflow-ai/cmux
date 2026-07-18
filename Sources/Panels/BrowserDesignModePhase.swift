/// Exclusive design-mode interaction: pick elements or draw capture regions.
enum BrowserDesignModeInteractionMode: String, Equatable {
    case select
    case draw
}

enum BrowserDesignModePhase: Equatable {
    case inactive
    case activating
    case active
    case deactivating

    var commandValue: String {
        switch self {
        case .inactive: "inactive"
        case .activating: "activating"
        case .active: "active"
        case .deactivating: "deactivating"
        }
    }
}

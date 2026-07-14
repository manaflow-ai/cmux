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

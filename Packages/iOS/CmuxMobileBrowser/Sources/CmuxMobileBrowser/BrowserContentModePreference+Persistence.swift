extension BrowserContentModePreference {
    init(persistenceRawValue: String) {
        switch persistenceRawValue {
        case "mobile": self = .mobile
        case "desktop": self = .desktop
        default: self = .recommended
        }
    }

    var persistenceRawValue: String {
        switch self {
        case .recommended: "recommended"
        case .mobile: "mobile"
        case .desktop: "desktop"
        }
    }
}

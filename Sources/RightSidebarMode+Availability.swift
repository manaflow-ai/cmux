import Foundation

extension RightSidebarMode {
    static func from(cliArgument rawValue: String) -> RightSidebarMode? {
        switch rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "files":
            return .files
        case "find":
            return .find
        case "vault", "sessions":
            return .sessions
        case "feed":
            return .feed
        case "dock":
            return .dock
        default:
            return nil
        }
    }

    static func availableModes(defaults: UserDefaults = .standard) -> [RightSidebarMode] {
        availableModes(dockEnabled: RightSidebarBetaFeatureSettings.isDockEnabled(defaults: defaults))
    }

    static func availableModes(dockEnabled: Bool) -> [RightSidebarMode] {
        allCases.filter { $0.isAvailable(dockEnabled: dockEnabled) }
    }

    func isAvailable(defaults: UserDefaults = .standard) -> Bool {
        isAvailable(dockEnabled: RightSidebarBetaFeatureSettings.isDockEnabled(defaults: defaults))
    }

    func isAvailable(dockEnabled: Bool) -> Bool {
        switch self {
        case .files, .find, .sessions, .feed:
            return true
        case .dock:
            return dockEnabled
        }
    }
}

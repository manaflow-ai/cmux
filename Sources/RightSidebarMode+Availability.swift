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
        default:
            return nil
        }
    }

    static func availableModes(defaults: UserDefaults = .standard) -> [RightSidebarMode] {
        allCases.filter { $0.isAvailable(defaults: defaults) }
    }

    func isAvailable(defaults _: UserDefaults = .standard) -> Bool {
        switch self {
        case .files, .find, .sessions, .feed:
            return true
        case .dock:
            return false
        }
    }
}

import Foundation

extension RightSidebarMode {
    static func from(cliArgument rawValue: String) -> RightSidebarMode? {
        switch rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "files":
            return .files
        case "notes":
            return .notes
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
        availableModes(
            notesEnabled: RightSidebarBetaFeatureSettings.isNotesEnabled(defaults: defaults),
            feedEnabled: RightSidebarBetaFeatureSettings.isFeedEnabled(defaults: defaults),
            dockEnabled: RightSidebarBetaFeatureSettings.isDockEnabled(defaults: defaults)
        )
    }

    static func availableModes(notesEnabled: Bool, feedEnabled: Bool, dockEnabled: Bool) -> [RightSidebarMode] {
        allCases.filter {
            $0.isAvailable(notesEnabled: notesEnabled, feedEnabled: feedEnabled, dockEnabled: dockEnabled)
        }
    }

    func isAvailable(defaults: UserDefaults = .standard) -> Bool {
        isAvailable(
            notesEnabled: RightSidebarBetaFeatureSettings.isNotesEnabled(defaults: defaults),
            feedEnabled: RightSidebarBetaFeatureSettings.isFeedEnabled(defaults: defaults),
            dockEnabled: RightSidebarBetaFeatureSettings.isDockEnabled(defaults: defaults)
        )
    }

    func isAvailable(notesEnabled: Bool, feedEnabled: Bool, dockEnabled: Bool) -> Bool {
        switch self {
        case .files, .find, .sessions:
            return true
        case .notes:
            return notesEnabled
        case .feed:
            return feedEnabled
        case .dock:
            return dockEnabled
        }
    }
}

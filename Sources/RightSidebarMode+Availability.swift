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
        case "artifacts":
            return .artifacts
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
            artifactsEnabled: RightSidebarBetaFeatureSettings.isArtifactsEnabled(defaults: defaults),
            feedEnabled: RightSidebarBetaFeatureSettings.isFeedEnabled(defaults: defaults),
            dockEnabled: RightSidebarBetaFeatureSettings.isDockEnabled(defaults: defaults)
        )
    }

    static func availableModes(
        artifactsEnabled: Bool,
        feedEnabled: Bool,
        dockEnabled: Bool
    ) -> [RightSidebarMode] {
        allCases.filter {
            $0 != .customSidebar && $0.isAvailable(
                artifactsEnabled: artifactsEnabled,
                feedEnabled: feedEnabled,
                dockEnabled: dockEnabled
            )
        }
    }

    func isAvailable(defaults: UserDefaults = .standard) -> Bool {
        isAvailable(
            artifactsEnabled: RightSidebarBetaFeatureSettings.isArtifactsEnabled(defaults: defaults),
            feedEnabled: RightSidebarBetaFeatureSettings.isFeedEnabled(defaults: defaults),
            dockEnabled: RightSidebarBetaFeatureSettings.isDockEnabled(defaults: defaults)
        )
    }

    func isAvailable(artifactsEnabled: Bool, feedEnabled: Bool, dockEnabled: Bool) -> Bool {
        switch self {
        case .files, .find, .sessions:
            return true
        case .artifacts:
            return artifactsEnabled
        case .feed:
            return feedEnabled
        case .dock:
            return dockEnabled
        case .customSidebar:
            return false
        }
    }
}

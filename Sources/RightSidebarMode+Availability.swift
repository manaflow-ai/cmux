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
        case "cloud", "machines", "vms":
            return .machines
        case "custom", "custom-sidebar":
            return .customSidebar
        default:
            return nil
        }
    }

    static func availableModes(defaults: UserDefaults = .standard) -> [RightSidebarMode] {
        availableModes(
            artifactsEnabled: RightSidebarBetaFeatureSettings.isArtifactsEnabled(defaults: defaults),
            feedEnabled: RightSidebarBetaFeatureSettings.isFeedEnabled(defaults: defaults),
            dockEnabled: RightSidebarBetaFeatureSettings.isDockEnabled(defaults: defaults),
            machinesEnabled: CloudMachinesFeature.offMainIsEnabled(defaults: defaults)
        )
    }

    static func availableModes(
        artifactsEnabled: Bool,
        feedEnabled: Bool,
        dockEnabled: Bool,
        machinesEnabled: Bool
    ) -> [RightSidebarMode] {
        allCases.filter {
            $0.isAvailable(
                artifactsEnabled: artifactsEnabled,
                feedEnabled: feedEnabled,
                dockEnabled: dockEnabled,
                machinesEnabled: machinesEnabled
            )
        }
    }

    /// Preserves the Cloud sidebar availability API for callers that do not
    /// participate in the Artifacts beta gate.
    static func availableModes(
        feedEnabled: Bool,
        dockEnabled: Bool,
        machinesEnabled: Bool
    ) -> [RightSidebarMode] {
        availableModes(
            artifactsEnabled: false,
            feedEnabled: feedEnabled,
            dockEnabled: dockEnabled,
            machinesEnabled: machinesEnabled
        )
    }

    func isAvailable(defaults: UserDefaults = .standard) -> Bool {
        isAvailable(
            artifactsEnabled: RightSidebarBetaFeatureSettings.isArtifactsEnabled(defaults: defaults),
            feedEnabled: RightSidebarBetaFeatureSettings.isFeedEnabled(defaults: defaults),
            dockEnabled: RightSidebarBetaFeatureSettings.isDockEnabled(defaults: defaults),
            machinesEnabled: CloudMachinesFeature.offMainIsEnabled(defaults: defaults)
        )
    }

    func isAvailable(
        artifactsEnabled: Bool,
        feedEnabled: Bool,
        dockEnabled: Bool,
        machinesEnabled: Bool
    ) -> Bool {
        switch self {
        case .files, .find, .sessions:
            return true
        case .artifacts:
            return artifactsEnabled
        case .feed:
            return feedEnabled
        case .dock:
            return dockEnabled
        case .machines:
            return machinesEnabled
        case .customSidebar:
            // Available once the custom-sidebars beta is on AND a right-side
            // sidebar has been picked (right_sidebar set custom <name>); the
            // mode bar then grows a Custom button.
            return CmuxExtensionSidebarSelection.customSidebarsEnabled
                && FileExplorerState.persistedCustomSidebarName() != nil
        }
    }

    /// Preserves the Cloud sidebar availability API for callers that do not
    /// participate in the Artifacts beta gate.
    func isAvailable(
        feedEnabled: Bool,
        dockEnabled: Bool,
        machinesEnabled: Bool
    ) -> Bool {
        isAvailable(
            artifactsEnabled: false,
            feedEnabled: feedEnabled,
            dockEnabled: dockEnabled,
            machinesEnabled: machinesEnabled
        )
    }
}

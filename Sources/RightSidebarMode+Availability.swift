import CmuxSidebar
import Foundation

// The pure CLI-argument decode and the gate-based availability/availableModes
// now live in CmuxSidebar (RightSidebarMode). These app-target overloads bind
// the `feedEnabled`/`dockEnabled` gates to the live `UserDefaults`-backed
// RightSidebarBetaFeatureSettings, which stays in the app target.
extension RightSidebarMode {
    static func availableModes(defaults: UserDefaults = .standard) -> [RightSidebarMode] {
        availableModes(
            feedEnabled: RightSidebarBetaFeatureSettings.isFeedEnabled(defaults: defaults),
            dockEnabled: RightSidebarBetaFeatureSettings.isDockEnabled(defaults: defaults)
        )
    }

    func isAvailable(defaults: UserDefaults = .standard) -> Bool {
        isAvailable(
            feedEnabled: RightSidebarBetaFeatureSettings.isFeedEnabled(defaults: defaults),
            dockEnabled: RightSidebarBetaFeatureSettings.isDockEnabled(defaults: defaults)
        )
    }
}

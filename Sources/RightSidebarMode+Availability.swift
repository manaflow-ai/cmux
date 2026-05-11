import Foundation

extension RightSidebarMode {
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

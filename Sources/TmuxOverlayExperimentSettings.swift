import Foundation

struct TmuxOverlayExperimentSettings {
    static let enabledKey = "tmuxOverlayExperimentEnabled"
    static let targetKey = "tmuxOverlayExperimentTarget"
    static let defaultEnabled = false
    static let defaultTarget: TmuxOverlayExperimentTarget = .surface

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: enabledKey) as? Bool ?? defaultEnabled
    }

    static func target(defaults: UserDefaults = .standard) -> TmuxOverlayExperimentTarget {
        target(
            enabled: isEnabled(defaults: defaults),
            rawValue: defaults.string(forKey: targetKey)
        )
    }

    static func target(enabled: Bool, rawValue: String?) -> TmuxOverlayExperimentTarget {
        guard enabled else { return .surface }
        guard let rawValue,
              let target = TmuxOverlayExperimentTarget(rawValue: rawValue) else {
            return defaultTarget
        }
        return target
    }
}

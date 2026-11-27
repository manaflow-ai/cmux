import CmuxSettings
import Foundation

enum TerminalScrollSpeedSettings {
    static let multiplierKey = "terminal.scrollSpeed"
    static let defaultMultiplier = TerminalCatalogSection.scrollSpeedDefault
    static let minimumMultiplier = TerminalCatalogSection.scrollSpeedMinimum
    static let maximumMultiplier = TerminalCatalogSection.scrollSpeedMaximum

    nonisolated static func multiplier(defaults: UserDefaults = .standard) -> Double {
        if defaults.object(forKey: multiplierKey) == nil {
            return defaultMultiplier
        }
        return sanitizedMultiplier(defaults.double(forKey: multiplierKey))
    }

    nonisolated static func sanitizedMultiplier(_ value: Double) -> Double {
        guard value.isFinite else { return defaultMultiplier }
        return min(max(value, minimumMultiplier), maximumMultiplier)
    }
}

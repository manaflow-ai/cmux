import Foundation

enum InternalFlagOverrideChoice: CaseIterable, Hashable, Identifiable {
    case on
    case off
    case noOverride

    var id: Self { self }

    var title: String {
        switch self {
        case .on:
            return String(localized: "featureFlags.override.on", defaultValue: "On")
        case .off:
            return String(localized: "featureFlags.override.off", defaultValue: "Off")
        case .noOverride:
            return String(localized: "featureFlags.override.none", defaultValue: "No override")
        }
    }

    var overrideValue: Bool? {
        switch self {
        case .on:
            return true
        case .off:
            return false
        case .noOverride:
            return nil
        }
    }
}

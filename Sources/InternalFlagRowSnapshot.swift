import Foundation

/// Immutable inspector state, captured above the SwiftUI lazy-list boundary.
struct InternalFlagRowSnapshot: Identifiable, Equatable {
    var id: String { definition.key }

    let definition: CmuxFeatureFlagDefinition
    let resolution: CmuxFeatureFlagResolution
    let overrideValue: Bool?

    @MainActor
    init(definition: CmuxFeatureFlagDefinition, flags: CmuxFeatureFlags) {
        self.definition = definition
        resolution = flags.resolution(for: definition)
        overrideValue = flags.overrideValue(for: definition)
    }

    var overrideNote: String? {
        if !resolution.allowsLocalOverride {
            return String(
                localized: "featureFlags.override.remoteControlledNote",
                defaultValue: "Controlled remotely; local override inactive."
            )
        }
        if definition.key == CmuxFeatureFlags.cloudMachinesFlag.key {
            return String(
                localized: "featureFlags.override.cloudDogfoodNote",
                defaultValue: "Cloud overrides take priority in this Nightly or debug build."
            )
        }
        return nil
    }

    var sourceTitle: String {
        switch resolution.source {
        case .remote:
            return String(localized: "featureFlags.source.remote", defaultValue: "Remote")
        case .override:
            return String(localized: "featureFlags.source.override", defaultValue: "Override")
        case .default:
            return String(localized: "featureFlags.source.default", defaultValue: "Default")
        }
    }

    var overrideChoice: InternalFlagOverrideChoice {
        switch overrideValue {
        case .some(true):
            return .on
        case .some(false):
            return .off
        case .none:
            return .noOverride
        }
    }
}

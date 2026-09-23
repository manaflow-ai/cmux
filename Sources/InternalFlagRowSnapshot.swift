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

    static func matches(query: String, title: String, key: String, description: String) -> Bool {
        let haystack = "\(title) \(key) \(description)".folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        return query
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .split(whereSeparator: { $0.isWhitespace || $0.isPunctuation })
            .allSatisfy { token in
                haystack.contains(token)
            }
    }

    func matches(query: String) -> Bool {
        Self.matches(
            query: query,
            title: definition.title,
            key: definition.key,
            description: definition.flagDescription
        )
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

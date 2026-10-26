import CmuxNextCompat
import CmuxNextDesign
import CmuxNextFeatures
import Foundation

/// The launch's local feature choices, resolution step 3 of its ``FeatureList`` (DEV and NIGHTLY only): the
/// Labs page's (``FeatureLocalOverrides``), else the Debug tunable the feature `replaces`
/// (`features.d/<name>.json`, ``Feature/replaces``), as the build's debug-tunables.json holds it. Both are read
/// on a launch lane before the list resolves, as Chrome applies about:flags at start
/// (components/flags_ui/pref_service_flags_storage.cc); a later change applies at the next launch.
nonisolated struct LaunchFeatureLocalOverrides: FeatureLocalOverrideProvider, Sendable, Equatable {
    var labs = FeatureLocalOverrides()
    /// Each replaced Bool tunable the developer set, by tunable key (``replacedTunables(in:keys:)``).
    var tunables: [String: Bool] = [:]

    func localOverride(for feature: Feature) -> Bool? {
        if let choice = labs.localOverride(for: feature) { return choice }
        for key in feature.replaces {
            if let value = tunables[key] { return value }
        }
        return nil
    }

    /// The tunable keys `features` replace: what ``replacedTunables(in:keys:)`` reads.
    static func replacedKeys(of features: [Feature]) -> Set<String> {
        Set(features.flatMap(\.replaces))
    }

    /// The Bool values `file` (a debug-tunables.json) holds for `keys`; none without the file, for a key it
    /// does not hold or for a value that is not a Bool. Blocking: a launch lane only.
    static func replacedTunables(in file: URL, keys: Set<String>) -> [String: Bool] {
        guard !keys.isEmpty, let data = try? Data(blockingContentsOf: file) else { return [:] }
        var values: [String: Bool] = [:]
        for (key, raw) in TunableFile.decode(data) where keys.contains(key) {
            if case .bool(let value)? = TunableFile.value(raw, as: .bool) { values[key] = value }
        }
        return values
    }
}

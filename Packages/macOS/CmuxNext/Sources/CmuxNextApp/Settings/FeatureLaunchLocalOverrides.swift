import CmuxNextCompat
import CmuxNextDesign
import CmuxNextFeatures
import Foundation

/// Step 3 of this launch's feature ladder (DEV and NIGHTLY): the Labs page's choice for a feature, else the
/// Debug Settings toggle the feature took over (its JSON's `replaces`). Both are read once at launch, so
/// ``FeatureList/resolution(of:)``, `features.list` and the Labs card report the value the code uses, with
/// source `local`; a toggle changed later applies at the next launch, as a Labs choice does (about:flags,
/// components/flags_ui/flags_state.cc, applied at start). A Labs choice wins: it names the feature itself.
nonisolated struct FeatureLaunchLocalOverrides: FeatureLocalOverrideProvider, Sendable, Equatable {
    /// The Labs page's choices (`local-overrides.json`).
    let labs: FeatureLocalOverrides
    /// The replaced toggles' values in the Debug Settings file, by feature name.
    let toggles: [String: Bool]

    init(labs: FeatureLocalOverrides = FeatureLocalOverrides(), toggles: [String: Bool] = [:]) {
        self.labs = labs
        self.toggles = toggles
    }

    func localOverride(for feature: Feature) -> Bool? {
        labs.localOverride(for: feature) ?? toggles[feature.name]
    }

    /// The value each feature of `registry` takes from `raw`, a Debug Settings file's `values`
    /// (``TunableFile/decode(_:)``): the first replaced key that holds a boolean. A key that is not a
    /// Bool toggle (an env switch, a number) gives none.
    static func toggles(in raw: [String: Any], registry: FeatureRegistry) -> [String: Bool] {
        var toggles: [String: Bool] = [:]
        for feature in registry.features {
            for key in feature.replaces {
                guard let json = raw[key], case .bool(let value)? = TunableFile.value(json, as: .bool) else { continue }
                toggles[feature.name] = value
                break
            }
        }
        return toggles
    }

    /// The replaced toggles in the Debug Settings file at `file`; no file, or one that does not parse,
    /// gives none. Blocking: the launch's files lane only.
    static func readToggles(_ file: URL, registry: FeatureRegistry) -> [String: Bool] {
        guard let data = try? Data(blockingContentsOf: file) else { return [:] }
        return toggles(in: TunableFile.decode(data), registry: registry)
    }
}

/// A launch's local feature choices, resolution step 3 of its ``FeatureList`` (DEV and NIGHTLY only): the
/// Labs page's (``FeatureLocalOverrides``), else the Debug tunable the feature `replaces`
/// (`features.d/<name>.json`, ``Feature/replaces``) as the developer set it. The App reads both on a launch
/// lane before the list resolves, as Chrome applies about:flags at start
/// (components/flags_ui/pref_service_flags_storage.cc); a later change applies at the next launch.
public nonisolated struct FeatureLaunchLocalOverrides: FeatureLocalOverrideProvider, Sendable, Equatable {
    public var labs: FeatureLocalOverrides
    /// Each replaced Bool tunable the developer set, by tunable key.
    public var tunables: [String: Bool]

    public init(labs: FeatureLocalOverrides = FeatureLocalOverrides(), tunables: [String: Bool] = [:]) {
        self.labs = labs
        self.tunables = tunables
    }

    public func localOverride(for feature: Feature) -> Bool? {
        if let choice = labs.localOverride(for: feature) { return choice }
        for key in feature.replaces {
            if let value = tunables[key] { return value }
        }
        return nil
    }

    /// The tunable keys `features` replace: the ones the App reads for ``tunables``.
    public static func replacedKeys(of features: [Feature]) -> Set<String> {
        Set(features.flatMap(\.replaces))
    }
}

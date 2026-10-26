/// The Debug Settings tunables a feature took over (its `replaces` keys), as that feature's local override
/// (resolution step 3): Chrome's about:flags entries that map a choice onto a `base::Feature`
/// (chrome/browser/about_flags.cc, `FEATURE_VALUE_TYPE`), read once at launch like the rest of the list.
/// `values` is the launch's Debug tunables file, by tunable key; a feature with several keys takes its first
/// set one, in `replaces` order. The ``FeatureList`` asks it only on DEV and NIGHTLY.
public nonisolated struct FeatureTunableOverrides: FeatureLocalOverrideProvider, Sendable, Equatable {
    /// The Bool tunables of the launch's file, by key.
    public let values: [String: Bool]

    public init(values: [String: Bool] = [:]) {
        self.values = values
    }

    public func localOverride(for feature: Feature) -> Bool? {
        for key in feature.replaces {
            if let value = values[key] { return value }
        }
        return nil
    }
}

/// Several local override providers asked in order: the first that has a value for a feature decides it.
/// The App puts the Labs page's choice (which names the feature) before the Debug tunable it replaced.
public nonisolated struct FeatureLocalOverrideLayers: FeatureLocalOverrideProvider, Sendable {
    public let layers: [any FeatureLocalOverrideProvider]

    public init(_ layers: [any FeatureLocalOverrideProvider]) {
        self.layers = layers
    }

    public func localOverride(for feature: Feature) -> Bool? {
        for layer in layers {
            if let value = layer.localOverride(for: feature) { return value }
        }
        return nil
    }
}

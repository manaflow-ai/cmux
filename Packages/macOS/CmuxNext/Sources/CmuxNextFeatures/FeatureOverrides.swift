import Foundation

/// Local Labs and Debug overrides (resolution step 3). The launch's provider,
/// ``FeatureLaunchLocalOverrides``, gives the Labs choice, else the Debug toggle
/// a feature replaced (``Feature/replaces``), read from the `TunableStore` file
/// at launch; the
/// ``FeatureList`` asks it only on DEV and NIGHTLY, so Release never reads it.
public protocol FeatureLocalOverrideProvider: Sendable {
    /// The value the developer chose for `feature`, or nil for none.
    func localOverride(for feature: Feature) -> Bool?
}

/// Every input to a ``FeatureList`` except the local provider, by feature
/// name. Names the registry does not declare are ignored and reported
/// (``FeatureList/unknownNames``), as Chrome ignores unknown names in
/// `--enable-features`.
public nonisolated struct FeatureOverrides: Sendable, Equatable {
    /// The environment variable that turns features off (comma separated).
    public static let disableVariable = "CMUX_DISABLE_FEATURES"
    /// The environment variable that turns features on (comma separated).
    public static let enableVariable = "CMUX_ENABLE_FEATURES"

    /// Managed policy `DisabledFeatures` (step 1): these are always off.
    public var policyDisabled: Set<String>
    /// `CMUX_DISABLE_FEATURES` (step 2). Beats ``environmentEnabled``.
    public var environmentDisabled: Set<String>
    /// `CMUX_ENABLE_FEATURES` (step 2).
    public var environmentEnabled: Set<String>
    /// The signed remote document's values, already filtered by safe mode (step 4).
    public var remote: [String: Bool]
    /// The field-trial arms (step 5): ``FieldTrials/values``, already filtered by channel and build.
    public var fieldTrial: [String: Bool]
    /// The features this build turns on by default (step 6, over the channel default): a dogfood build's switch set,
    /// ``FeatureDogfoodSet/buildDefaults(forTag:)``. Empty in every other build.
    public var buildDefaults: Set<String>

    public init(
        policyDisabled: Set<String> = [],
        environmentDisabled: Set<String> = [],
        environmentEnabled: Set<String> = [],
        remote: [String: Bool] = [:],
        fieldTrial: [String: Bool] = [:],
        buildDefaults: Set<String> = []
    ) {
        self.policyDisabled = policyDisabled
        self.environmentDisabled = environmentDisabled
        self.environmentEnabled = environmentEnabled
        self.remote = remote
        self.fieldTrial = fieldTrial
        self.buildDefaults = buildDefaults
    }

    /// Reads both environment lists from `environment` (the launch
    /// environment the App captured; this type never reads the process).
    public init(
        policyDisabled: Set<String> = [],
        environment: [String: String],
        remote: [String: Bool] = [:],
        fieldTrial: [String: Bool] = [:],
        buildDefaults: Set<String> = []
    ) {
        self.init(
            policyDisabled: policyDisabled,
            environmentDisabled: Self.names(in: environment[Self.disableVariable]),
            environmentEnabled: Self.names(in: environment[Self.enableVariable]),
            remote: remote,
            fieldTrial: fieldTrial,
            buildDefaults: buildDefaults
        )
    }

    /// The names of a comma-separated list (`a, b,,c`): trimmed of spaces
    /// and newlines, empties dropped, as Chrome's `SplitFeatureListString`
    /// (base/feature_list.cc, `TRIM_WHITESPACE`).
    public static func names(in list: String?) -> Set<String> {
        guard let list else { return [] }
        var names: Set<String> = []
        for part in list.split(separator: ",") {
            let name = part.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty { names.insert(name) }
        }
        return names
    }

    /// Every name any input mentions.
    var mentionedNames: Set<String> {
        policyDisabled
            .union(environmentDisabled)
            .union(environmentEnabled)
            .union(remote.keys)
            .union(fieldTrial.keys)
            .union(buildDefaults)
    }
}

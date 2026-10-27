public import CmuxNextCompat

/// One declared feature: Chromium's `base::Feature` (base/feature_list.h).
///
/// The declarations come from `schemas/features/features.d/<name>.json`, one
/// file per feature, which `scripts/cmux-next/gen-features.py` turns into one
/// handle per feature and ``Feature/registered`` (Features.generated.swift;
/// the interface is in schemas/features/README.md). A handle
/// carries its slot in the registry, so ``FeatureList/isEnabled(_:)`` is one
/// array load, as Chrome caches a feature's state on the `base::Feature`.
public nonisolated struct Feature: Sendable, Hashable {
    /// The build channel a default is chosen for.
    public enum Channel: String, Sendable, CaseIterable {
        case dev
        case nightly
        case release

        /// The channel of a build kind: RC ships as Release; staging and
        /// processes outside a bundle (tests, tools) take the DEV defaults.
        public init(_ kind: BuildIdentity.Kind) {
            switch kind {
            case .nightly: self = .nightly
            case .release, .rc: self = .release
            case .dev, .staging, .unbundled: self = .dev
            }
        }

        /// Whether local Labs and Debug overrides apply (DEV and NIGHTLY).
        public var allowsLocalOverrides: Bool { self != .release }
    }

    /// What a feature is for (the registry's `kind`).
    public enum Kind: String, Sendable, CaseIterable {
        /// A performance path benched in both arms; expires within 60 days.
        case perfPath
        /// An emergency off switch for shipped behavior.
        case killSwitch
        /// A Labs experiment the person can turn on.
        case labs
    }

    /// The process whose behavior the feature changes.
    public enum TargetProcess: String, Sendable, CaseIterable {
        case app
        case daemon
        case both
        /// Maps into CEF `--enable-features`/`--disable-features`.
        case chromium
    }

    /// The input that decided a feature's value, highest precedence first.
    public enum Source: UInt8, Sendable, CaseIterable, CustomStringConvertible {
        /// Managed policy `DisabledFeatures`.
        case policy
        /// `CMUX_DISABLE_FEATURES` or `CMUX_ENABLE_FEATURES`.
        case environment
        /// A Labs or Debug override (DEV and NIGHTLY only).
        case local
        /// The signed remote flags document.
        case remote
        /// A Nightly field-trial arm.
        case fieldTrial
        /// The build's own default set: a dogfood build's switch list (``FeatureOverrides/buildDefaults``).
        case buildDefault
        /// The channel default.
        case channelDefault

        public var description: String {
            switch self {
            case .policy: "policy"
            case .environment: "env"
            case .local: "local"
            case .remote: "remote"
            case .fieldTrial: "trial"
            case .buildDefault: "build"
            case .channelDefault: "default"
            }
        }
    }

    /// A resolved value and the input that decided it.
    public struct Resolution: Sendable, Hashable, CustomStringConvertible {
        public let isEnabled: Bool
        public let source: Source

        public init(isEnabled: Bool, source: Source) {
            self.isEnabled = isEnabled
            self.source = source
        }

        /// `on source=remote`, the form `cmux settings feature-flags` prints.
        public var description: String { "\(isEnabled ? "on" : "off") source=\(source)" }
    }

    /// The feature's slot in its ``FeatureRegistry``.
    public let index: Int
    /// The registry name (`features.d/<name>.json`), as written in the
    /// environment lists, the policy and the remote document.
    public let name: String
    /// The owner in plans/cmux-next/OWNERS.md or a `PL-*` workstream.
    public let owner: String
    /// One sentence: what turning the feature on changes (Labs page, reports).
    public let description: String
    public let kind: Kind
    public let process: TargetProcess
    /// The Chromium `base::Feature` passed to CEF, for process `chromium` only.
    public let chromiumFeature: String?
    public let defaults: FeatureDefaults
    /// `YYYY-MM-DD` for a perfPath feature, else nil.
    public let expires: String?
    /// The typed params (`base::FeatureParam`).
    public let params: [FeatureParamSpec]
    /// The lab stories that bench both arms.
    public let stories: [String]
    /// A remote off stays off in safe mode.
    public let sticky: Bool
    /// The feature has a tested live-teardown path.
    public let runtimeMutable: Bool
    /// The Debug tunables and environment switches this feature took over
    /// (`replaces` in its file): a replaced tunable the developer set is the
    /// feature's local override (resolution step 3).
    public let replaces: [String]

    /// The generated registry (`Features.generated.swift`) calls this with
    /// every label, in this order (schemas/features/README.md).
    public init(
        index: Int,
        name: String,
        owner: String,
        description: String,
        kind: Kind,
        process: TargetProcess,
        chromiumFeature: String?,
        defaults: FeatureDefaults,
        expires: String?,
        params: [FeatureParamSpec],
        stories: [String],
        sticky: Bool,
        runtimeMutable: Bool,
        replaces: [String] = []
    ) {
        self.index = index
        self.name = name
        self.owner = owner
        self.description = description
        self.kind = kind
        self.process = process
        self.chromiumFeature = chromiumFeature
        self.defaults = defaults
        self.expires = expires
        self.params = params
        self.stories = stories
        self.sticky = sticky
        self.runtimeMutable = runtimeMutable
        self.replaces = replaces
    }

    /// Duration param `name`'s value, to the microsecond: its declared default, since params have no
    /// override source yet. Nil when the feature declares no duration param of that name.
    public func durationParam(_ name: String) -> Duration? {
        for param in params where param.name == name {
            // Whole microseconds: `.seconds(0.2)` would carry the double's error into the attoseconds.
            if case let .duration(seconds, _, _) = param.value { return .microseconds(Int64((seconds * 1_000_000).rounded())) }
        }
        return nil
    }
}

/// The default value per channel, the last step of the resolution order.
public nonisolated struct FeatureDefaults: Sendable, Hashable {
    public let dev: Bool
    public let nightly: Bool
    public let release: Bool

    public init(dev: Bool, nightly: Bool, release: Bool) {
        self.dev = dev
        self.nightly = nightly
        self.release = release
    }

    /// The same default on every channel.
    public init(all value: Bool) {
        self.init(dev: value, nightly: value, release: value)
    }

    public func value(for channel: Feature.Channel) -> Bool {
        switch channel {
        case .dev: dev
        case .nightly: nightly
        case .release: release
        }
    }
}

/// One typed param of a feature: Chromium's `base::FeatureParam`
/// (base/metrics/field_trial_params.h).
public nonisolated struct FeatureParamSpec: Sendable, Hashable {
    public let name: String
    public let description: String
    public let value: FeatureParamValue

    public init(name: String, description: String, value: FeatureParamValue) {
        self.name = name
        self.description = description
        self.value = value
    }
}

/// A param's type, default and bounds. The generator checks that numbers
/// are finite and that each default is inside its bounds.
public nonisolated enum FeatureParamValue: Sendable, Hashable {
    case int(default: Int, min: Int, max: Int)
    case double(default: Double, min: Double, max: Double)
    /// Seconds.
    case duration(default: Double, min: Double, max: Double)
    case bool(default: Bool)
}

/// Every declared feature, in slot order (the generated registry, or a test's).
public nonisolated struct FeatureRegistry: Sendable {
    public let features: [Feature]
    private let indexByName: [String: Int]

    /// The generated registry: every feature in schemas/features/features.d.
    public init() {
        self.init(Feature.registered)
    }

    /// `features[i].index` must be `i` and names must be unique: the
    /// generator guarantees both (test_gen_features.py), so a violation is a
    /// generator bug and stops a debug build.
    public init(_ features: [Feature]) {
        var indexByName: [String: Int] = [:]
        indexByName.reserveCapacity(features.count)
        for (slot, feature) in features.enumerated() {
            assert(feature.index == slot, "feature \(feature.name) declares slot \(feature.index), registered at \(slot)")
            let previous = indexByName.updateValue(slot, forKey: feature.name)
            assert(previous == nil, "feature \(feature.name) is declared twice")
        }
        self.features = features
        self.indexByName = indexByName
    }

    public var count: Int { features.count }

    /// The feature named `name`, for names read from text (env, policy,
    /// remote document, CLI). Code holds the generated handles instead.
    public func feature(named name: String) -> Feature? {
        indexByName[name].map { features[$0] }
    }

    /// Whether `feature` is this registry's handle (same slot, same name).
    public func contains(_ feature: Feature) -> Bool {
        features.indices.contains(feature.index) && features[feature.index].name == feature.name
    }
}

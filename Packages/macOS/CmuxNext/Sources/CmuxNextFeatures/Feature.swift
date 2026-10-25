public import CmuxNextCompat

/// One declared feature: Chromium's `base::Feature` (base/feature_list.h).
///
/// The declarations come from `schemas/features/features.d/<name>.json`, one
/// file per feature, which `scripts/cmux-next/gen-features.py` (task 090)
/// turns into a ``FeatureRegistry`` and one handle per feature. A handle
/// carries its slot in the registry, so ``FeatureList/isEnabled(_:)`` is one
/// array load, as Chrome caches a feature's state on the `base::Feature`.
public nonisolated struct Feature: Sendable, Hashable, CustomStringConvertible {
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

        /// Whether field-trial arms apply (Nightly studies only).
        public var allowsFieldTrials: Bool { self == .nightly }
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
    public enum Process: String, Sendable, CaseIterable {
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
        /// The channel default.
        case channelDefault

        public var description: String {
            switch self {
            case .policy: "policy"
            case .environment: "env"
            case .local: "local"
            case .remote: "remote"
            case .fieldTrial: "trial"
            case .channelDefault: "default"
            }
        }
    }

    /// The default value per channel.
    public struct Defaults: Sendable, Hashable {
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

        public func value(for channel: Channel) -> Bool {
            switch channel {
            case .dev: dev
            case .nightly: nightly
            case .release: release
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
    public let defaults: Defaults
    public let kind: Kind
    public let process: Process
    /// A remote off stays off in safe mode.
    public let isSticky: Bool
    /// The feature has a tested live-teardown path; false until it does.
    public let isRuntimeMutable: Bool

    public init(
        index: Int,
        name: String,
        defaults: Defaults,
        kind: Kind,
        process: Process = .app,
        isSticky: Bool = false,
        isRuntimeMutable: Bool = false
    ) {
        self.index = index
        self.name = name
        self.defaults = defaults
        self.kind = kind
        self.process = process
        self.isSticky = isSticky
        self.isRuntimeMutable = isRuntimeMutable
    }

    public var description: String { name }
}

/// Every declared feature, in slot order (the generated registry, or a test's).
public nonisolated struct FeatureRegistry: Sendable {
    public let features: [Feature]
    private let indexByName: [String: Int]

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

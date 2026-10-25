import Atomics

/// The resolved value of every feature: Chromium's `base::FeatureList`
/// (base/feature_list.cc), built once by the composition root and immutable
/// after that, so ``isEnabled(_:)`` is one array load and needs no lock.
///
/// Resolution order, highest first (plans/cmux-next/chrome-parity/
/// p12-perf-process.md section 3.9):
/// 1. managed policy `DisabledFeatures` (off only)
/// 2. `CMUX_DISABLE_FEATURES` / `CMUX_ENABLE_FEATURES`; a name on both is
///    off, as in Chrome ("If a feature appears on both lists, then it will
///    be disabled")
/// 3. local Labs and Debug overrides, DEV and NIGHTLY only
/// 4. the signed remote document, already filtered by safe mode
/// 5. the Nightly field-trial arm
/// 6. the channel default
public nonisolated final class FeatureList: Sendable {
    public let registry: FeatureRegistry
    public let channel: Feature.Channel
    /// Names an input mentions that the registry does not declare, sorted.
    public let unknownNames: [String]
    @usableFromInline let resolutions: ContiguousArray<Feature.Resolution>

    /// Resolves every feature of `registry` once. `local` is asked only when
    /// `channel` allows local overrides, once per feature.
    public init(
        registry: FeatureRegistry,
        channel: Feature.Channel,
        overrides: FeatureOverrides = FeatureOverrides(),
        local: (any FeatureLocalOverrideProvider)? = nil
    ) {
        let local = channel.allowsLocalOverrides ? local : nil
        var resolutions = ContiguousArray<Feature.Resolution>()
        resolutions.reserveCapacity(registry.count)
        for feature in registry.features {
            resolutions.append(Self.resolve(feature, channel: channel, overrides: overrides, local: local))
        }
        self.registry = registry
        self.channel = channel
        self.resolutions = resolutions
        unknownNames = overrides.mentionedNames.filter { registry.feature(named: $0) == nil }.sorted()
    }

    /// Whether `feature` is on. One array load; `feature` must be a handle of
    /// this list's registry.
    @inlinable
    public func isEnabled(_ feature: Feature) -> Bool {
        assert(registry.contains(feature), "feature \(feature.name) is not declared in this list's registry")
        return resolutions[feature.index].isEnabled
    }

    /// The value of `feature` and the input that decided it.
    public func resolution(of feature: Feature) -> Feature.Resolution {
        assert(registry.contains(feature), "feature \(feature.name) is not declared in this list's registry")
        return resolutions[feature.index]
    }

    /// Every feature with its resolution, in registry order (Labs page,
    /// `cmux settings feature-flags`, reports).
    public var entries: [(feature: Feature, resolution: Feature.Resolution)] {
        zip(registry.features, resolutions).map { (feature: $0, resolution: $1) }
    }

    private static func resolve(
        _ feature: Feature,
        channel: Feature.Channel,
        overrides: FeatureOverrides,
        local: (any FeatureLocalOverrideProvider)?
    ) -> Feature.Resolution {
        let name = feature.name
        if overrides.policyDisabled.contains(name) { return Feature.Resolution(isEnabled: false, source: .policy) }
        if overrides.environmentDisabled.contains(name) { return Feature.Resolution(isEnabled: false, source: .environment) }
        if overrides.environmentEnabled.contains(name) { return Feature.Resolution(isEnabled: true, source: .environment) }
        if let value = local?.localOverride(for: feature) { return Feature.Resolution(isEnabled: value, source: .local) }
        if let value = overrides.remote[name] { return Feature.Resolution(isEnabled: value, source: .remote) }
        if channel.allowsFieldTrials, let value = overrides.fieldTrial[name] {
            return Feature.Resolution(isEnabled: value, source: .fieldTrial)
        }
        return Feature.Resolution(isEnabled: feature.defaults.value(for: channel), source: .channelDefault)
    }
}

extension FeatureList {
    /// The place a ``FeatureList`` is installed into, for code that may run
    /// before the composition root has built it. Before install a read
    /// answers the channel default and, in DEBUG and bench builds, is
    /// recorded, as Chrome records an access before
    /// `FeatureList::SetInstance` (base/feature_list.cc, early access).
    /// Code built after install takes the ``FeatureList`` itself.
    public nonisolated final class Slot: Sendable {
        /// Whether this build records early reads: DEBUG and bench builds.
        #if DEBUG || CMUX_BENCH_HOOKS
        public static let recordsEarlyReadsInThisBuild = true
        #else
        public static let recordsEarlyReadsInThisBuild = false
        #endif

        private let installed = ManagedAtomicLazyReference<FeatureList>()
        private let defaults: FeatureList
        /// One flag per feature while recording, else empty.
        private let earlyReadFlags: [ManagedAtomic<Bool>]

        public init(
            registry: FeatureRegistry,
            channel: Feature.Channel,
            recordsEarlyReads: Bool = FeatureList.Slot.recordsEarlyReadsInThisBuild
        ) {
            defaults = FeatureList(registry: registry, channel: channel)
            earlyReadFlags = recordsEarlyReads ? registry.features.map { _ in ManagedAtomic(false) } : []
        }

        /// The installed list, or nil before ``install(_:)``.
        public var list: FeatureList? { installed.load() }

        /// Whether `feature` is on: the installed list's value, else the
        /// channel default (and the read is recorded).
        public func isEnabled(_ feature: Feature) -> Bool {
            if let list = installed.load() { return list.isEnabled(feature) }
            if !earlyReadFlags.isEmpty { earlyReadFlags[feature.index].store(true, ordering: .relaxed) }
            return defaults.isEnabled(feature)
        }

        /// The features read before install, in registry order (empty when not recording).
        public var earlyReads: [Feature] {
            zip(defaults.registry.features, earlyReadFlags).compactMap { feature, flag in
                flag.load(ordering: .relaxed) ? feature : nil
            }
        }

        /// Installs `list` once and returns the early reads that got a value
        /// other than the installed one: code that ran on the wrong value.
        /// A second install, or a list of another registry, is a
        /// composition-root bug: it is ignored and stops a debug build.
        @discardableResult
        public func install(_ list: FeatureList) -> [Feature] {
            guard list.registry.features == defaults.registry.features else {
                assertionFailure("the installed FeatureList has another registry")
                return []
            }
            let winner = installed.storeIfNilThenLoad(list)
            guard winner === list else {
                assertionFailure("a FeatureList is installed twice")
                return []
            }
            return earlyReads.filter { list.isEnabled($0) != defaults.isEnabled($0) }
        }
    }
}

import Atomics
public import class CmuxSafeConcurrency.Invariant

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
/// 5. the field-trial arm (``FieldTrials`` keeps only the studies of this
///    build's channel: Nightly unless a study names another)
/// 6. the build's default set (a dogfood build's switch list, ``FeatureOverrides/buildDefaults``: on), else
///    the channel default
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
        Invariant.debugCheck(registry.contains(feature), "feature-in-list-registry",
                             "feature \(feature.name) is not declared in this list's registry")
        return resolutions[feature.index].isEnabled
    }

    /// The value of `feature` and the input that decided it.
    public func resolution(of feature: Feature) -> Feature.Resolution {
        Invariant.debugCheck(registry.contains(feature), "feature-resolution-in-list-registry",
                             "feature \(feature.name) is not declared in this list's registry")
        return resolutions[feature.index]
    }

    /// `localOverride` when it decides `feature` in step 3, else nil: the Debug tunable the feature replaced,
    /// whose file loads after the list is built, so each reader (the feature's one seam and `features.list`)
    /// passes its value at each decision. It applies on DEV and NIGHTLY where neither policy nor the
    /// environment lists decided the feature, over the remote document, the field trial and the channel
    /// default, as Chrome keeps about:flags entries under policy and the command line (chrome/browser/about_flags.cc).
    public func effectiveLocalOverride(_ feature: Feature, localOverride: Bool?) -> Bool? {
        let source = resolution(of: feature).source
        guard channel.allowsLocalOverrides, source != .policy, source != .environment else { return nil }
        return localOverride
    }

    /// Whether `feature` is on with `localOverride` in step 3 (``effectiveLocalOverride(_:localOverride:)``).
    public func isEnabled(_ feature: Feature, localOverride: Bool?) -> Bool {
        effectiveLocalOverride(feature, localOverride: localOverride) ?? resolution(of: feature).isEnabled
    }

    /// Every feature with its resolution, in registry order (Labs page,
    /// `cmux settings feature-flags`, reports).
    public var entries: [(feature: Feature, resolution: Feature.Resolution)] {
        zip(registry.features, resolutions).map { (feature: $0, resolution: $1) }
    }

    /// The Chromium `base::Feature` names of the enabled features of process `chromium`, in registry
    /// order: what CEF gets in `--enable-features`.
    public var enabledChromiumFeatures: [String] {
        zip(registry.features, resolutions).compactMap { feature, resolution in
            feature.process == .chromium && resolution.isEnabled ? feature.chromiumFeature : nil
        }
    }

    /// The Chromium `base::Feature` names of the off features of process `chromium`, in registry order:
    /// what CEF gets in `--disable-features`. Every off one is listed, whatever decided it (the channel
    /// default, the remote document, policy, the environment), so the registry states each Chromium
    /// feature it maps and a remote off reaches Chromium as an off, not as Chromium's own default.
    public var disabledChromiumFeatures: [String] {
        zip(registry.features, resolutions).compactMap { feature, resolution in
            feature.process == .chromium && !resolution.isEnabled ? feature.chromiumFeature : nil
        }
    }

    /// The daemons' features (process `daemon` or `both`) this list did not take from the channel
    /// default, as `CMUX_ENABLE_FEATURES` and `CMUX_DISABLE_FEATURES` for a daemon's spawn
    /// environment (an empty list is left out), so a daemon whose launch filters what it inherits
    /// resolves them as the app did: Chrome's `FeatureList::AddFeaturesToCommandLine`
    /// (base/feature_list.cc) gives a child process only the overridden features the same way.
    public var daemonEnvironment: [String: String] {
        var enabled: [String] = []
        var disabled: [String] = []
        for (feature, resolution) in zip(registry.features, resolutions)
        where (feature.process == .daemon || feature.process == .both) && resolution.source != .channelDefault {
            if resolution.isEnabled { enabled.append(feature.name) } else { disabled.append(feature.name) }
        }
        var environment: [String: String] = [:]
        if !enabled.isEmpty { environment[FeatureOverrides.enableVariable] = enabled.joined(separator: ",") }
        if !disabled.isEmpty { environment[FeatureOverrides.disableVariable] = disabled.joined(separator: ",") }
        return environment
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
        if let value = overrides.fieldTrial[name] { return Feature.Resolution(isEnabled: value, source: .fieldTrial) }
        if overrides.buildDefaults.contains(name) { return Feature.Resolution(isEnabled: true, source: .buildDefault) }
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
        ///
        /// Reads may race ``install(_:)`` on any thread. The flag store, a
        /// sequentially consistent fence and a second load here pair with the
        /// fence in ``install(_:)`` (Dekker): either this read sees the list,
        /// or install sees the flag. So a read that answered the default is
        /// always reported; a read that raced install and then saw the list
        /// may be reported too.
        public func isEnabled(_ feature: Feature) -> Bool {
            if let list = installed.load() { return list.isEnabled(feature) }
            if !earlyReadFlags.isEmpty {
                earlyReadFlags[feature.index].store(true, ordering: .relaxed)
                atomicMemoryFence(ordering: .sequentiallyConsistent)
                if let list = installed.load() { return list.isEnabled(feature) }
            }
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
                Invariant.debugCheck(false, "installed-feature-list-registry", "the installed FeatureList has another registry")
                return []
            }
            let winner = installed.storeIfNilThenLoad(list)
            guard winner === list else {
                Invariant.debugCheck(false, "feature-list-installed-once", "a FeatureList is installed twice")
                return []
            }
            // Pairs with the fence in isEnabled(_:): every flag a reader set
            // before it missed the list is visible from here.
            atomicMemoryFence(ordering: .sequentiallyConsistent)
            return earlyReads.filter { list.isEnabled($0) != defaults.isEnabled($0) }
        }
    }
}

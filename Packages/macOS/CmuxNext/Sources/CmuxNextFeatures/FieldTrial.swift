/// One study this install is in, and its arm: Chrome's field trial group
/// (base/metrics/field_trial.h, `FieldTrial::ActiveGroup`). It is in effect only where its arm
/// decides the feature (``FieldTrials/inEffect(in:localOverride:)``); a hang report then names the
/// feature as `name=on|off@trial` (task p12-perf-process-151's non-default features), and
/// `field.py` splits every field metric by ``fieldTag``.
public nonisolated struct FieldTrial: Sendable, Hashable, CustomStringConvertible {
    public let study: String
    public let arm: String
    /// The registry name of the feature the arm sets.
    public let feature: String
    /// The feature's value in the arm.
    public let isEnabled: Bool

    public init(study: String, arm: String, feature: String, isEnabled: Bool) {
        self.study = study
        self.arm = arm
        self.feature = feature
        self.isEnabled = isEnabled
    }

    /// `study=arm`, for logs and diagnostics.
    public var description: String { "\(study)=\(arm)" }

    /// `feature=on|off`: the arm as `field.py` names it from a report's `features[]` entry of source
    /// `trial`. One study owns a feature and an arm only sets its state, so this is the arm.
    public var fieldTag: String { "\(feature)=\(isEnabled ? "on" : "off")" }
}

/// Why a study of the flags document gives this install no arm.
public nonisolated enum FieldTrialSkip: Sendable, Hashable, CustomStringConvertible {
    /// The study runs on other channels (`channel`, `nightly` when absent).
    case otherChannel(study: String, channels: [String])
    /// This build is below the study's `min_build`.
    case buildBelowMinimum(study: String, build: UInt64, minimum: UInt64)
    /// This build is above the study's `max_build`.
    case buildAboveMaximum(study: String, build: UInt64, maximum: UInt64)
    /// The study names a build range and this build has no number.
    case buildUnknown(study: String)
    /// The study's feature is not a perfPath feature (or not declared): studies compare performance paths.
    case notPerfPath(study: String, feature: String)
    /// The study has no arm with a weight above 0.
    case noWeight(study: String)
    /// An arm's state is not `on` or `off`.
    case badArmState(study: String, arm: String, state: String)
    /// An earlier study already sets the feature; the first study keeps it, as Chrome lets one field
    /// trial own a feature (base/feature_list.cc, `RegisterOverride`).
    case featureTaken(study: String, feature: String, by: String)
    /// Two studies share a name; the first keeps it.
    case duplicateStudy(study: String)

    public var description: String {
        switch self {
        case .otherChannel(let study, let channels): "study \(study) runs on \(channels.joined(separator: ","))"
        case .buildBelowMinimum(let study, let build, let minimum): "study \(study): build \(build) is below min_build \(minimum)"
        case .buildAboveMaximum(let study, let build, let maximum): "study \(study): build \(build) is above max_build \(maximum)"
        case .buildUnknown(let study): "study \(study) names a build range and this build has no build number"
        case .notPerfPath(let study, let feature): "study \(study): feature \(feature) is not a perfPath feature"
        case .noWeight(let study): "study \(study) has no arm with a weight"
        case .badArmState(let study, let arm, let state): "study \(study) arm \(arm) has state \(state), not on or off"
        case .featureTaken(let study, let feature, let by): "study \(study): feature \(feature) is already in study \(by)"
        case .duplicateStudy(let study): "study \(study) is listed twice"
        }
    }
}

/// The arms this install is in: resolution step 5 (``FeatureOverrides/fieldTrial``), as Chrome's
/// `VariationsSeedProcessor` turns the seed's studies into field trials
/// (components/variations/variations_seed_processor.cc) after the filters of
/// components/variations/study_filtering.cc.
///
/// A study applies on the channels it names (`channel`, a comma-separated list; `nightly` when
/// absent), so a Release build ignores every study that does not name `release`. It also applies
/// only to builds in its `min_build` ... `max_build` range (inclusive). Its arm is picked by the
/// install's ``LowEntropySource`` ranked for the study's name (``LowEntropySource/rank(forStudy:)``):
/// the same install keeps the same arm, and each arm gets its weight's share of installs.
public nonisolated struct FieldTrials: Sendable, Equatable {
    /// The channel of a study that names none.
    public static let defaultChannel = Feature.Channel.nightly

    /// The studies this install is in, in document order.
    public let active: [FieldTrial]
    /// The studies left out, in document order.
    public let skipped: [FieldTrialSkip]

    public init(active: [FieldTrial], skipped: [FieldTrialSkip]) {
        self.active = active
        self.skipped = skipped
    }

    /// No study.
    public static let none = FieldTrials(active: [], skipped: [])

    /// The arms `studies` give the install of `entropy` on a build of `channel` numbered `build`.
    ///
    /// - Parameters:
    ///   - studies: ``FeatureRemoteOverrides/studies`` of the document this launch applies.
    ///   - registry: the registry; a study of a feature that is not perfPath is skipped.
    ///   - entropy: the install's ``LowEntropySource``.
    ///   - channel: this build's channel.
    ///   - build: `CFBundleVersion` as an integer; nil when it is not one.
    public init(
        studies: [FeatureStudy],
        registry: FeatureRegistry,
        entropy: LowEntropySource,
        channel: Feature.Channel,
        build: UInt64?
    ) {
        var active: [FieldTrial] = []
        var skipped: [FieldTrialSkip] = []
        var studyOfFeature: [String: String] = [:]
        var seen: Set<String> = []
        for study in studies {
            guard seen.insert(study.name).inserted else {
                skipped.append(.duplicateStudy(study: study.name))
                continue
            }
            if let skip = Self.filter(study, registry: registry, channel: channel, build: build) {
                skipped.append(skip)
                continue
            }
            if let owner = studyOfFeature[study.feature] {
                skipped.append(.featureTaken(study: study.name, feature: study.feature, by: owner))
                continue
            }
            guard let trial = Self.arm(of: study, entropy: entropy) else {
                skipped.append(.noWeight(study: study.name))
                continue
            }
            studyOfFeature[study.feature] = study.name
            active.append(trial)
        }
        self.init(active: active, skipped: skipped)
    }

    /// Feature name to its arm's value: ``FeatureOverrides/fieldTrial``.
    public var values: [String: Bool] {
        Dictionary(active.map { ($0.feature, $0.isEnabled) }, uniquingKeysWith: { first, _ in first })
    }

    /// The active trials whose arm decides its feature in `list`, in document order: the ones field data
    /// may count in their arm. A feature that policy, the environment lists, a Labs override or the remote
    /// document decides (``FeatureList`` steps 1 to 4), or that a late Debug tunable changes
    /// (``FeatureList/effectiveLocalOverride(_:localOverride:)``), is not in its study's arm. Chrome
    /// activates a trial only when its own override is the one in use: base/feature_list.cc keeps the
    /// command-line override over the trial's and activates the trial only when its entry is read.
    ///
    /// - Parameters:
    ///   - list: the launch's list, built with ``values`` as ``FeatureOverrides/fieldTrial``.
    ///   - localOverride: the Debug tunable the feature replaced, read after the list was built; nil for none.
    public func inEffect(in list: FeatureList, localOverride: (Feature) -> Bool? = { _ in nil }) -> [FieldTrial] {
        active.filter { trial in
            guard let feature = list.registry.feature(named: trial.feature) else { return false }
            let resolution = list.resolution(of: feature)
            return resolution.source == .fieldTrial && resolution.isEnabled == trial.isEnabled
                && list.effectiveLocalOverride(feature, localOverride: localOverride(feature)) == nil
        }
    }

    /// The channels a study names: its `channel` list, else ``defaultChannel``. Unknown names are kept,
    /// so the skip reason shows them, and match no build.
    public static func channels(of study: FeatureStudy) -> [String] {
        let names = study.channel.map { FeatureOverrides.names(in: $0).sorted() } ?? []
        return names.isEmpty ? [defaultChannel.rawValue] : names
    }

    private static func filter(_ study: FeatureStudy, registry: FeatureRegistry, channel: Feature.Channel, build: UInt64?) -> FieldTrialSkip? {
        let named = Self.channels(of: study)
        guard named.contains(channel.rawValue) else { return .otherChannel(study: study.name, channels: named) }
        if study.minBuild != nil || study.maxBuild != nil {
            guard let build else { return .buildUnknown(study: study.name) }
            if let minimum = study.minBuild, build < minimum {
                return .buildBelowMinimum(study: study.name, build: build, minimum: minimum)
            }
            if let maximum = study.maxBuild, build > maximum {
                return .buildAboveMaximum(study: study.name, build: build, maximum: maximum)
            }
        }
        guard registry.feature(named: study.feature)?.kind == .perfPath else {
            return .notPerfPath(study: study.name, feature: study.feature)
        }
        if let bad = study.arms.first(where: { $0.state != "on" && $0.state != "off" }) {
            return .badArmState(study: study.name, arm: bad.name, state: bad.state)
        }
        guard study.arms.contains(where: { $0.weight > 0 }) else { return .noWeight(study: study.name) }
        return nil
    }

    /// The arm whose share of the total weight holds the install's rank, as Chrome's
    /// `FieldTrial::AppendGroup` gives each group the next `probability` slice of the divisor
    /// (base/metrics/field_trial.cc). Nil only for a study with no weight, which ``filter`` skips first.
    private static func arm(of study: FeatureStudy, entropy: LowEntropySource) -> FieldTrial? {
        let total = study.arms.reduce(UInt64(0)) { $0 + UInt64($1.weight) }
        guard total > 0 else { return nil }
        // The rank's slot of the total weight; below `total`, since the rank is below the domain.
        let slot = UInt64(entropy.rank(forStudy: study.name)) * total / UInt64(LowEntropySource.domain)
        var end: UInt64 = 0
        for arm in study.arms {
            end += UInt64(arm.weight)
            if slot < end {
                return FieldTrial(study: study.name, arm: arm.name, feature: study.feature, isEnabled: arm.state == "on")
            }
        }
        return nil
    }
}

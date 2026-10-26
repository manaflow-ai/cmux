import Foundation

/// The arms this install runs: Chrome's `FieldTrialList` after
/// `VariationsFieldTrialCreator` applied the seed
/// (components/variations/service/variations_field_trial_creator.cc).
///
/// The composition root builds it once, off the main thread, from the
/// verified flags document's studies (``FieldTrialStudy/decodeList(_:)``)
/// and the install's ``LowEntropySource``, before the ``FeatureList``.
/// ``featureStates`` is the list's field-trial input (resolution step 5,
/// ``FeatureOverrides/fieldTrial``) and ``reportEntries`` goes into the
/// opt-in hang report beside the non-default features (task 151).
public nonisolated struct FieldTrials: Sendable, Hashable {
    /// One running study and the arm this install is in.
    public nonisolated struct ActiveArm: Sendable, Hashable, CustomStringConvertible {
        public let study: String
        public let feature: String
        public let arm: String
        public let isEnabled: Bool
        /// The arm came from ``FieldTrials/forceVariable``, not the entropy.
        public let isForced: Bool

        public init(study: String, feature: String, arm: String, isEnabled: Bool, isForced: Bool) {
            self.study = study
            self.feature = feature
            self.arm = arm
            self.isEnabled = isEnabled
            self.isForced = isForced
        }

        /// The report entry: `study=arm`.
        public var description: String { "\(study)=\(arm)" }
    }

    /// Forces arms, Chrome's `--force-fieldtrials`: `study/arm[,study/arm]`.
    /// A forced arm still needs its study to run on this channel and build.
    public static let forceVariable = "CMUX_FORCE_FIELD_TRIALS"
    /// The hang report key that carries ``reportEntries`` (task 151), which
    /// `scripts/perf-lab/field.py` splits field metrics by.
    public static let reportKey = "fieldTrials"

    /// The running studies' arms, in document order.
    public let active: [ActiveArm]
    /// The studies whose filter leaves them out of this build, by name.
    public let excluded: [String: FieldTrialExclusion]
    /// The studies and forced arms rejected, in document order.
    public let rejected: [FieldTrialRejection]

    /// No studies.
    public init() {
        active = []
        excluded = [:]
        rejected = []
    }

    /// Picks an arm for each study that runs on `channel` at `build`.
    ///
    /// A study is rejected for a name used before, an unknown or
    /// non-perfPath feature, or a feature an earlier running study already
    /// sets (Chrome refuses two trials that associate the same feature).
    /// Without `entropy` (its store failed) only forced arms run: an arm
    /// that changed per launch would mix both arms' data in one install.
    public init(
        studies: [FieldTrialStudy],
        registry: FeatureRegistry,
        channel: Feature.Channel,
        build: String,
        entropy: LowEntropySource?,
        forced: [String: String] = [:]
    ) {
        var active: [ActiveArm] = []
        var excluded: [String: FieldTrialExclusion] = [:]
        var rejected: [FieldTrialRejection] = []
        var names: Set<String> = []
        var studyOfFeature: [String: String] = [:]
        for study in studies {
            let error: FieldTrialError?
            if !names.insert(study.name).inserted {
                error = .duplicateStudy(study.name)
            } else if let feature = registry.feature(named: study.feature) {
                error = feature.kind == .perfPath ? nil : .notPerfPath(study.feature)
            } else {
                error = .unknownFeature(study.feature)
            }
            if let error {
                rejected.append(FieldTrialRejection(study: study.name, error: error))
                continue
            }
            if let exclusion = study.exclusion(channel: channel, build: build) {
                excluded[study.name] = exclusion
                continue
            }
            if let first = studyOfFeature[study.feature] {
                rejected.append(FieldTrialRejection(study: study.name, error: .featureInTwoStudies(feature: study.feature, first: first)))
                continue
            }
            var forcedArm: FieldTrialStudy.Arm?
            if let forcedName = forced[study.name] {
                forcedArm = study.arm(named: forcedName)
                if forcedArm == nil { rejected.append(FieldTrialRejection(study: study.name, error: .forcedArmUnknown(forcedName))) }
            }
            guard let arm = forcedArm ?? entropy.map({ study.arm(for: $0) }) else { continue }
            studyOfFeature[study.feature] = study.name
            active.append(ActiveArm(
                study: study.name,
                feature: study.feature,
                arm: arm.name,
                isEnabled: arm.isEnabled,
                isForced: forcedArm != nil
            ))
        }
        for study in forced.keys.sorted() where !names.contains(study) {
            rejected.append(FieldTrialRejection(study: study, error: .forcedStudyUnknown(study)))
        }
        self.active = active
        self.excluded = excluded
        self.rejected = rejected
    }

    /// Each running study's feature value, for ``FeatureOverrides/fieldTrial``.
    public var featureStates: [String: Bool] {
        Dictionary(uniqueKeysWithValues: active.map { ($0.feature, $0.isEnabled) })
    }

    /// `study=arm` per running study, sorted: the ``reportKey`` value.
    public var reportEntries: [String] {
        active.map(\.description).sorted()
    }

    /// The forced arms in `environment[forceVariable]` (the launch
    /// environment the App captured), by study. A part without `/` forces
    /// the arm `""`, which no study has, so it is reported, never dropped.
    public static func forcedArms(in environment: [String: String]) -> [String: String] {
        var arms: [String: String] = [:]
        for part in (environment[forceVariable] ?? "").split(separator: ",") {
            let entry = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !entry.isEmpty else { continue }
            let pieces = entry.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
            arms[String(pieces[0])] = pieces.count > 1 ? String(pieces[1]) : ""
        }
        return arms
    }
}

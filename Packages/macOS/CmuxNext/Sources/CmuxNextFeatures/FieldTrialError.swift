/// Why a study, or a forced arm, is rejected.
public nonisolated enum FieldTrialError: Error, Sendable, Hashable, CustomStringConvertible {
    /// The entry is not a study object (the decoder's reason).
    case malformed(String)
    case invalidName(String)
    case invalidBuild(String)
    case unknownChannel(String)
    case noChannel
    case noArms
    case duplicateArm(String)
    /// The arm's state is not `on` or `off`.
    case invalidState(arm: String)
    /// A weight below 0, or a sum above ``FieldTrialStudy/maxTotalWeight``.
    case invalidWeight(arm: String)
    case zeroTotalWeight
    /// Two studies share a name: the later one is rejected.
    case duplicateStudy(String)
    case unknownFeature(String)
    /// Field trials set perfPath features only.
    case notPerfPath(String)
    /// The feature already has a running study: the later one is rejected.
    case featureInTwoStudies(feature: String, first: String)
    /// ``FieldTrials/forceVariable`` names an arm the study does not have.
    case forcedArmUnknown(String)
    /// ``FieldTrials/forceVariable`` names a study the document does not have.
    case forcedStudyUnknown(String)

    public var description: String {
        switch self {
        case let .malformed(reason): "malformed study: \(reason)"
        case let .invalidName(name): "invalid name \"\(name)\""
        case let .invalidBuild(build): "invalid build bound \"\(build)\""
        case let .unknownChannel(channel): "unknown channel \"\(channel)\""
        case .noChannel: "no channel"
        case .noArms: "no arms"
        case let .duplicateArm(arm): "arm \(arm) declared twice"
        case let .invalidState(arm): "arm \(arm): state is not on or off"
        case let .invalidWeight(arm): "arm \(arm): weight out of range"
        case .zeroTotalWeight: "the weights sum to 0"
        case let .duplicateStudy(study): "study \(study) declared twice"
        case let .unknownFeature(feature): "unknown feature \(feature)"
        case let .notPerfPath(feature): "feature \(feature) is not a perfPath feature"
        case let .featureInTwoStudies(feature, first): "feature \(feature) already runs in study \(first)"
        case let .forcedArmUnknown(arm): "forced arm \"\(arm)\" is not in the study"
        case let .forcedStudyUnknown(study): "forced study \(study) is not in the document"
        }
    }
}

/// A rejected study and why, for the log and `cmux settings feature-flags`.
public nonisolated struct FieldTrialRejection: Error, Sendable, Hashable, CustomStringConvertible {
    /// The study's name, nil when the entry has none that can be read.
    public let study: String?
    public let error: FieldTrialError

    public init(study: String?, error: FieldTrialError) {
        self.study = study
        self.error = error
    }

    public var description: String { "study \(study ?? "?"): \(error)" }
}

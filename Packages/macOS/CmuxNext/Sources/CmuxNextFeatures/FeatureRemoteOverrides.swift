public import Foundation

/// One entry of an accepted document that is ignored, with the reason.
public nonisolated enum FeatureRemoteIgnoredEntry: Sendable, Hashable, CustomStringConvertible {
    /// A `Features` name the registry does not declare.
    case unknownFeature(String)
    /// A `Features` value other than `"on"` or `"off"`.
    case badValue(feature: String, value: String)
    /// A study of a feature the registry does not declare.
    case unknownStudyFeature(study: String, feature: String)

    public var description: String {
        switch self {
        case .unknownFeature(let name): "unknown feature \(name)"
        case .badValue(let name, let value): "feature \(name) has value \(value), not on or off"
        case .unknownStudyFeature(let study, let name): "study \(study) names unknown feature \(name)"
        }
    }
}

/// What the document is checked against: the registry, the person's cohort
/// and this build's number.
public nonisolated struct FeatureRemoteContext: Sendable {
    public let registry: FeatureRegistry
    /// `tester.cohort`, else ``FeatureRemoteDocument/defaultCohort``.
    public let cohort: String
    /// `CFBundleVersion` as an integer; nil when it is not one (local builds).
    public let build: UInt64?

    public init(registry: FeatureRegistry, cohort: String = FeatureRemoteDocument.defaultCohort, build: UInt64?) {
        self.registry = registry
        self.cohort = cohort
        self.build = build
    }

    /// The context of a build whose `CFBundleVersion` is `bundleVersion`.
    public init(registry: FeatureRegistry, cohort: String = FeatureRemoteDocument.defaultCohort, bundleVersion: String?) {
        self.init(registry: registry, cohort: cohort, build: bundleVersion.flatMap { UInt64($0) })
    }
}

/// The remote values one document gives this build (resolution step 4,
/// before safe mode): what ``FeatureOverrides/remote`` takes.
public nonisolated struct FeatureRemoteOverrides: Sendable, Equatable {
    /// The document's `FeaturesSerial` (reports, `cmux settings feature-flags`).
    public let serial: UInt64
    /// Registry name to value.
    public let values: [String: Bool]
    /// The studies of declared features.
    public let studies: [FeatureStudy]
    /// The entries left out, in name order.
    public let ignored: [FeatureRemoteIgnoredEntry]

    public init(serial: UInt64, values: [String: Bool], studies: [FeatureStudy], ignored: [FeatureRemoteIgnoredEntry]) {
        self.serial = serial
        self.values = values
        self.studies = studies
        self.ignored = ignored
    }

    /// No document.
    public static let none = FeatureRemoteOverrides(serial: 0, values: [:], studies: [], ignored: [])

    /// The values `document` gives the build of `context` at `now`. A passed
    /// expiry or a build outside the range drops the whole document, as
    /// Chrome drops a study outside its version filter
    /// (components/variations/study_filtering.cc); an unknown name or a bad
    /// value drops that entry only, as Chrome ignores an unknown name in
    /// `--enable-features` (base/feature_list.cc).
    public init(_ document: FeatureRemoteDocument, context: FeatureRemoteContext, now: Date) throws(FeatureRemoteDocumentError) {
        if let expiresAt = document.expiresAt, now >= expiresAt { throw .expired(at: expiresAt) }
        if document.minBuild != nil || document.maxBuild != nil {
            guard let build = context.build else { throw .buildUnknown }
            if let minimum = document.minBuild, build < minimum { throw .buildBelowMinimum(build: build, minimum: minimum) }
            if let maximum = document.maxBuild, build > maximum { throw .buildAboveMaximum(build: build, maximum: maximum) }
        }
        var values: [String: Bool] = [:]
        var ignored: [FeatureRemoteIgnoredEntry] = []
        for (name, value) in document.features.sorted(by: { $0.key < $1.key }) {
            guard context.registry.feature(named: name) != nil else {
                ignored.append(.unknownFeature(name))
                continue
            }
            switch value {
            case "on": values[name] = true
            case "off": values[name] = false
            default: ignored.append(.badValue(feature: name, value: value))
            }
        }
        var studies: [FeatureStudy] = []
        for study in document.studies {
            if context.registry.feature(named: study.feature) == nil {
                ignored.append(.unknownStudyFeature(study: study.name, feature: study.feature))
            } else {
                studies.append(study)
            }
        }
        self.init(serial: document.serial, values: values, studies: studies, ignored: ignored)
    }
}

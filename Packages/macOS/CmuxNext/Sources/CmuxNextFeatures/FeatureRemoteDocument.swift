public import Foundation

/// The feature keys of the signed flags document (`notes/flags.json`, from
/// `release-notes/next/flags.json`), for one cohort: Chrome's variations seed
/// (components/variations/proto/variations_seed.proto) in the document the
/// nightly already signs (plans/cmux-next/chrome-parity/p12-perf-process.md
/// section 3.9).
///
/// ```json
/// { "version": 1,
///   "default": { "Features": { "cefTimerSlack": "off" }, "FeaturesSerial": 7,
///                "FeaturesExpiresAt": "2026-12-01T00:00:00Z",
///                "FeaturesMinBuild": 1500, "FeaturesMaxBuild": 1600,
///                "FeatureParams": { "intentPrewarmHover": { "dwell": "0.1" } } },
///   "cohorts": { "wave-1": { "Features": { "cefTimerSlack": "on" }, "FeaturesSerial": 8 } } }
/// ```
///
/// A cohort's key replaces the default's whole, as the daemon's reader does
/// (cmux-tui `feature_flags.rs`, `resolve`): a cohort that changes one feature
/// repeats the default's other names. Keys the app does not read
/// (`DisabledFeatures`, `MinimumVersion`) are left to their readers.
/// Parse only bytes whose signature verified (``FeatureRemoteSignatureCheck``).
public nonisolated struct FeatureRemoteDocument: Sendable, Equatable {
    /// The only document version; `nightly.yml` asserts it when it publishes.
    public static let version = 1
    /// The cohort of a person in no test wave.
    public static let defaultCohort = "default"

    /// `FeaturesSerial`: raised by every publish that changes the feature
    /// keys; a lower one is a rollback and is refused
    /// (``FeatureRemoteDocumentError/lowerSerial(document:stored:)``). Every
    /// document has one, even with no `Features` (`nightly.yml` asserts it),
    /// so a document that ends every override has a serial above the one it
    /// replaces.
    public let serial: UInt64
    /// `FeaturesExpiresAt`: after it the document turns nothing on or off.
    public let expiresAt: Date?
    /// `FeaturesMinBuild`: the lowest `CFBundleVersion` it applies to (inclusive).
    public let minBuild: UInt64?
    /// `FeaturesMaxBuild`: the highest `CFBundleVersion` it applies to (inclusive).
    public let maxBuild: UInt64?
    /// `Features`: name to `"on"` or `"off"`, as written; ``FeatureRemoteOverrides`` checks both.
    public let features: [String: String]
    /// `Studies`: the Nightly field trials (task p12-perf-process-152 assigns arms).
    public let studies: [FeatureStudy]
    /// `FeatureParams`: feature name to param name to value text, as Chrome's
    /// `FieldTrialParams`; ``FeatureParamList`` checks each against the registry.
    public let params: [String: [String: String]]

    public init(
        serial: UInt64,
        expiresAt: Date? = nil,
        minBuild: UInt64? = nil,
        maxBuild: UInt64? = nil,
        features: [String: String] = [:],
        studies: [FeatureStudy] = [],
        params: [String: [String: String]] = [:]
    ) {
        self.serial = serial
        self.expiresAt = expiresAt
        self.minBuild = minBuild
        self.maxBuild = maxBuild
        self.features = features
        self.studies = studies
        self.params = params
    }

    /// The keys `data` sets for `cohort`: the default's, each replaced by the cohort's.
    public init(json data: Data, cohort: String) throws(FeatureRemoteDocumentError) {
        let wire: Wire
        do {
            wire = try JSONDecoder().decode(Wire.self, from: data)
        } catch {
            throw .malformed(String(describing: error))
        }
        guard wire.version == Self.version else { throw .unsupportedVersion(wire.version) }
        let base = wire.default ?? Keys()
        let layer = wire.cohorts?[cohort] ?? Keys()
        let features = layer.features ?? base.features ?? [:]
        let studies = layer.studies ?? base.studies ?? []
        let params = layer.params ?? base.params ?? [:]
        // Without a serial a replayed old document could not be told from a new one.
        guard let serial = layer.serial ?? base.serial else { throw .missingSerial }
        var expiresAt: Date?
        if let text = layer.expiresAt ?? base.expiresAt {
            do {
                expiresAt = try Date.ISO8601FormatStyle().parse(text)
            } catch {
                throw .malformed("FeaturesExpiresAt \(text) is not an ISO 8601 time")
            }
        }
        let minBuild = layer.minBuild ?? base.minBuild
        let maxBuild = layer.maxBuild ?? base.maxBuild
        if let minBuild, let maxBuild, minBuild > maxBuild {
            throw .malformed("FeaturesMinBuild \(minBuild) is above FeaturesMaxBuild \(maxBuild)")
        }
        self.init(
            serial: serial,
            expiresAt: expiresAt,
            minBuild: minBuild,
            maxBuild: maxBuild,
            features: features,
            studies: studies.map(\.study),
            params: params.mapValues { $0.mapValues(\.text) }
        )
    }

    /// The document as published. Unknown top-level and policy keys are ignored.
    private struct Wire: Decodable {
        let version: Int?
        let `default`: Keys?
        let cohorts: [String: Keys]?
    }

    /// The feature keys of `default` or of one cohort.
    private struct Keys: Decodable {
        var features: [String: String]?
        var serial: UInt64?
        var expiresAt: String?
        var minBuild: UInt64?
        var maxBuild: UInt64?
        var studies: [StudyWire]?
        var params: [String: [String: ParamWire]]?

        enum CodingKeys: String, CodingKey {
            case features = "Features"
            case serial = "FeaturesSerial"
            case expiresAt = "FeaturesExpiresAt"
            case minBuild = "FeaturesMinBuild"
            case maxBuild = "FeaturesMaxBuild"
            case studies = "Studies"
            case params = "FeatureParams"
        }
    }

    /// One `FeatureParams` value: text, or a JSON number or boolean written as
    /// its text (`8`, `0.05`, `true`), so the registry's parse decides either way.
    /// Any other JSON value decodes too, to a marker no param type parses, so
    /// ``FeatureParamList`` rejects that one value and the document still
    /// applies, as a bad `FieldTrialParams` value never invalidates Chrome's seed.
    private struct ParamWire: Decodable {
        let text: String

        init(from decoder: any Decoder) throws {
            let value = try decoder.singleValueContainer()
            if let text = try? value.decode(String.self) {
                self.text = text
            } else if let flag = try? value.decode(Bool.self) {
                text = String(flag)
            } else if let integer = try? value.decode(Int.self) {
                text = String(integer)
            } else if let number = try? value.decode(Double.self) {
                text = String(number)
            } else if value.decodeNil() {
                text = "null"
            } else if (try? decoder.unkeyedContainer()) != nil {
                text = "[…]"
            } else if (try? decoder.container(keyedBy: AnyKey.self)) != nil {
                text = "{…}"
            } else {
                text = "<unrepresentable number>"
            }
        }

        /// Any object key: only used to tell an object from other values.
        private struct AnyKey: CodingKey {
            let stringValue: String
            var intValue: Int? { nil }

            init(stringValue: String) {
                self.stringValue = stringValue
            }

            init?(intValue _: Int) {
                nil
            }
        }
    }

    /// One `Studies` entry as published (snake case, as task 152 names it).
    private struct StudyWire: Decodable {
        let name: String
        let feature: String
        let arms: [ArmWire]
        let channel: String?
        let minBuild: UInt64?
        let maxBuild: UInt64?

        enum CodingKeys: String, CodingKey {
            case name, feature, arms, channel
            case minBuild = "min_build"
            case maxBuild = "max_build"
        }

        var study: FeatureStudy {
            FeatureStudy(
                name: name,
                feature: feature,
                arms: arms.map { FeatureStudy.Arm(name: $0.name, weight: $0.weight, state: $0.state) },
                channel: channel,
                minBuild: minBuild,
                maxBuild: maxBuild
            )
        }
    }

    private struct ArmWire: Decodable {
        let name: String
        let weight: UInt32
        let state: String
    }
}

/// One Nightly field trial of the flags document (`Studies`), as Chrome's
/// `Study` (components/variations/proto/study.proto): its arms are picked by
/// task p12-perf-process-152 from a stable per-install value.
public nonisolated struct FeatureStudy: Sendable, Hashable {
    /// One arm: its share of installs and the feature's value in it.
    public struct Arm: Sendable, Hashable {
        public let name: String
        public let weight: UInt32
        /// `"on"` or `"off"`, as written.
        public let state: String

        public init(name: String, weight: UInt32, state: String) {
            self.name = name
            self.weight = weight
            self.state = state
        }
    }

    public let name: String
    /// The registry name of the feature the arms set.
    public let feature: String
    public let arms: [Arm]
    /// The channel it runs on (`nightly` when absent).
    public let channel: String?
    public let minBuild: UInt64?
    public let maxBuild: UInt64?

    public init(name: String, feature: String, arms: [Arm], channel: String?, minBuild: UInt64?, maxBuild: UInt64?) {
        self.name = name
        self.feature = feature
        self.arms = arms
        self.channel = channel
        self.minBuild = minBuild
        self.maxBuild = maxBuild
    }
}

/// Why a whole flags document gives this build nothing. The store refuses a
/// fetched document, and keeps its copy, for a bad signature, a document that
/// does not parse (`malformed`, `unsupportedVersion`, `missingSerial`) and a
/// lower serial; it stores one that has expired or excludes this build, which
/// then gives nothing (``FeatureRemoteOverrides``).
public nonisolated enum FeatureRemoteDocumentError: Error, Sendable, Equatable, CustomStringConvertible {
    /// The signature does not verify with a trusted key.
    case badSignature
    /// Not JSON of the document's shape (the reason says where).
    case malformed(String)
    /// `version` is not 1.
    case unsupportedVersion(Int?)
    /// No `FeaturesSerial` for the cohort (in `default` or its own key).
    case missingSerial
    /// A lower `FeaturesSerial` than the stored document's: a replayed old document.
    case lowerSerial(document: UInt64, stored: UInt64)
    /// `FeaturesExpiresAt` has passed.
    case expired(at: Date)
    /// This build is below `FeaturesMinBuild`.
    case buildBelowMinimum(build: UInt64, minimum: UInt64)
    /// This build is above `FeaturesMaxBuild`.
    case buildAboveMaximum(build: UInt64, maximum: UInt64)
    /// The document names a build range and this build has no number (`CFBundleVersion` is not an integer).
    case buildUnknown

    public var description: String {
        switch self {
        case .badSignature: "the signature does not verify"
        case .malformed(let reason): "malformed: \(reason)"
        case .unsupportedVersion(let version): "version \(version.map { "\($0)" } ?? "none") is not \(FeatureRemoteDocument.version)"
        case .missingSerial: "no FeaturesSerial"
        case .lowerSerial(let document, let stored): "FeaturesSerial \(document) is below the stored \(stored)"
        case .expired(let date): "expired at \(date.formatted(Date.ISO8601FormatStyle()))"
        case .buildBelowMinimum(let build, let minimum): "build \(build) is below FeaturesMinBuild \(minimum)"
        case .buildAboveMaximum(let build, let maximum): "build \(build) is above FeaturesMaxBuild \(maximum)"
        case .buildUnknown: "the document names a build range and this build has no build number"
        }
    }
}


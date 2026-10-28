import CmuxNextCompat
import CmuxNextFeatures
import CmuxNextWakeups
import Foundation
import Testing

/// Nightly field trials: Finch-style arms from the flags document's `Studies`, picked by the install's
/// low-entropy value (p12-perf-process.md section 3.9;
/// components/variations/entropy_provider.cc, components/variations/study_filtering.cc).
struct FieldTrialTests {
    private static let slack = feature(0, "slackThing", .perfPath)
    private static let prefetch = feature(1, "prefetchThing", .perfPath)
    private static let kill = feature(2, "killThing", .killSwitch)
    private static let registry = FeatureRegistry([slack, prefetch, kill])

    private static func feature(_ index: Int, _ name: String, _ kind: Feature.Kind) -> Feature {
        Feature(
            index: index,
            name: name,
            owner: "PL-test",
            description: "A test feature.",
            kind: kind,
            process: .app,
            chromiumFeature: nil,
            defaults: FeatureDefaults(all: false),
            expires: nil,
            params: [],
            stories: [],
            sticky: false,
            runtimeMutable: false
        )
    }

    private static func study(
        _ name: String = "slackStudy",
        feature: String = "slackThing",
        arms: [(String, UInt32, String)] = [("on", 50, "on"), ("off", 50, "off")],
        channel: String? = nil,
        minBuild: UInt64? = nil,
        maxBuild: UInt64? = nil
    ) -> FeatureStudy {
        FeatureStudy(name: name, feature: feature, arms: arms.map { FeatureStudy.Arm(name: $0.0, weight: $0.1, state: $0.2) },
                     channel: channel, minBuild: minBuild, maxBuild: maxBuild)
    }

    private static func entropy(_ value: Int) -> LowEntropySource {
        guard let source = LowEntropySource(value: value) else { preconditionFailure("\(value) is outside 0 ..< 8000") }
        return source
    }

    private static func trials(
        _ studies: [FeatureStudy],
        entropy value: Int = 1234,
        channel: Feature.Channel = .nightly,
        build: UInt64? = 1500
    ) -> FieldTrials {
        FieldTrials(studies: studies, registry: registry, entropy: entropy(value), channel: channel, build: build)
    }

    // MARK: The low-entropy value

    @Test func theValueIsInsideTheDomain() {
        #expect(LowEntropySource(value: -1) == nil)
        #expect(LowEntropySource(value: 8000) == nil)
        #expect(LowEntropySource(value: 0)?.value == 0)
        #expect(LowEntropySource(value: 7999)?.value == 7999)
        var generator = SystemRandomNumberGenerator()
        for _ in 0 ..< 100 {
            #expect((0 ..< LowEntropySource.domain).contains(LowEntropySource(using: &generator).value))
        }
    }

    /// The ranks are MurmurHash3 x86_32 (seed: the hash of the study name; data: the value's two little-endian
    /// bytes), as a Python port of the reference computes them (that port gives "hello" 0x248bfa47, the
    /// published vector).
    @Test func ranksMatchTheReferenceHash() {
        #expect(Self.entropy(0).rank(forStudy: "cefTimerSlackStudy") == 6243)
        #expect(Self.entropy(1).rank(forStudy: "cefTimerSlackStudy") == 7683)
        #expect(Self.entropy(4321).rank(forStudy: "cefTimerSlackStudy") == 5535)
        #expect(Self.entropy(7999).rank(forStudy: "cefTimerSlackStudy") == 2007)
    }

    // MARK: Arms

    @Test func aFixedValueAlwaysGetsTheSameArm() {
        let studies = [Self.study(), Self.study("prefetchStudy", feature: "prefetchThing")]
        for value in [0, 1, 1234, 4321, 7999] {
            let first = Self.trials(studies, entropy: value)
            #expect(first.active.count == 2)
            #expect(Self.trials(studies, entropy: value) == first)
        }
    }

    /// Every one of the 8000 values ranks once per study, so each arm gets its weight's share; the acceptance
    /// is within 1 %.
    @Test func armSharesAreTheirWeightsOverAllValues() {
        let even = Self.study()
        let uneven = Self.study("prefetchStudy", feature: "prefetchThing", arms: [("a", 10, "on"), ("b", 30, "off"), ("c", 60, "on")])
        var counts: [String: Int] = [:]
        var ranks = Set<Int>()
        for value in 0 ..< LowEntropySource.domain {
            ranks.insert(Self.entropy(value).rank(forStudy: even.name))
            for trial in Self.trials([even, uneven], entropy: value).active {
                counts[trial.description, default: 0] += 1
            }
        }
        #expect(ranks.count == LowEntropySource.domain)
        let expected: [String: Double] = [
            "slackStudy=on": 0.5, "slackStudy=off": 0.5,
            "prefetchStudy=a": 0.1, "prefetchStudy=b": 0.3, "prefetchStudy=c": 0.6,
        ]
        #expect(Set(counts.keys) == Set(expected.keys))
        for (tag, share) in expected {
            let measured = Double(counts[tag, default: 0]) / Double(LowEntropySource.domain)
            #expect(abs(measured - share) <= 0.01, "\(tag): \(measured), want \(share)")
        }
    }

    /// Two studies order the values their own way, so the installs of one study's arm split across the other's.
    @Test func twoStudiesAreIndependent() {
        let first = Self.study()
        let second = Self.study("prefetchStudy", feature: "prefetchThing")
        var both = 0
        var firstOn = 0
        for value in 0 ..< 2000 {
            let active = Self.trials([first, second], entropy: value).active
            guard active.first?.arm == "on" else { continue }
            firstOn += 1
            if active.last?.arm == "on" { both += 1 }
        }
        #expect(firstOn > 0)
        #expect(abs(Double(both) / Double(firstOn) - 0.5) < 0.1)
    }

    @Test func aZeroWeightArmGetsNoInstall() {
        let study = Self.study(arms: [("on", 0, "on"), ("off", 1, "off")])
        for value in stride(from: 0, to: LowEntropySource.domain, by: 97) {
            #expect(Self.trials([study], entropy: value).active.map(\.arm) == ["off"])
        }
    }

    // MARK: Filters

    @Test func maxBuildExcludesLaterBuilds() {
        let study = Self.study(minBuild: 1400, maxBuild: 1500)
        #expect(Self.trials([study], build: 1500).active.count == 1)
        #expect(Self.trials([study], build: 1400).active.count == 1)
        #expect(Self.trials([study], build: 1501).skipped == [.buildAboveMaximum(study: "slackStudy", build: 1501, maximum: 1500)])
        #expect(Self.trials([study], build: 1399).skipped == [.buildBelowMinimum(study: "slackStudy", build: 1399, minimum: 1400)])
        #expect(Self.trials([study], build: nil).skipped == [.buildUnknown(study: "slackStudy")])
        #expect(Self.trials([Self.study()], build: nil).active.count == 1)
    }

    @Test func releaseIgnoresStudiesUnlessNamed() {
        let nightlyOnly = Self.study()
        #expect(Self.trials([nightlyOnly], channel: .nightly).active.count == 1)
        #expect(Self.trials([nightlyOnly], channel: .release).skipped == [.otherChannel(study: "slackStudy", channels: ["nightly"])])
        #expect(Self.trials([nightlyOnly], channel: .dev).active.isEmpty)
        let named = Self.study(channel: "nightly, release")
        #expect(Self.trials([named], channel: .release).active.count == 1)
        #expect(Self.trials([named], channel: .dev).active.isEmpty)
        #expect(Self.trials([Self.study(channel: "beta")], channel: .nightly).skipped == [.otherChannel(study: "slackStudy", channels: ["beta"])])
    }

    @Test func badStudiesAreSkippedWithAReason() {
        let skipped = Self.trials([
            Self.study("killStudy", feature: "killThing"),
            Self.study("ghostStudy", feature: "ghostThing"),
            Self.study("emptyStudy", arms: [("on", 0, "on")]),
            Self.study("noArms", arms: []),
            Self.study("badState", arms: [("on", 1, "enabled")]),
            Self.study(),
            Self.study(),
            Self.study("secondSlack"),
        ]).skipped
        #expect(skipped == [
            .notPerfPath(study: "killStudy", feature: "killThing"),
            .notPerfPath(study: "ghostStudy", feature: "ghostThing"),
            .noWeight(study: "emptyStudy"),
            .noWeight(study: "noArms"),
            .badArmState(study: "badState", arm: "on", state: "enabled"),
            .duplicateStudy(study: "slackStudy"),
            .featureTaken(study: "secondSlack", feature: "slackThing", by: "slackStudy"),
        ])
    }

    // MARK: Into the feature list and reports

    @Test func armsAreResolutionStepFive() {
        let trials = Self.trials([Self.study(arms: [("on", 1, "on")])])
        #expect(trials.values == ["slackThing": true])
        let list = FeatureList(registry: Self.registry, channel: .nightly, overrides: FeatureOverrides(fieldTrial: trials.values))
        #expect(list.resolution(of: Self.slack) == Feature.Resolution(isEnabled: true, source: .fieldTrial))
        let remote = FeatureList(registry: Self.registry, channel: .nightly,
                                 overrides: FeatureOverrides(remote: ["slackThing": false], fieldTrial: trials.values))
        #expect(remote.resolution(of: Self.slack) == Feature.Resolution(isEnabled: false, source: .remote))
    }

    @Test func trialsInEffectAreTheOnesTheirArmDecides() {
        let trials = Self.trials([
            Self.study("zStudy", arms: [("treatment", 1, "on")]),
            Self.study("aStudy", feature: "prefetchThing", arms: [("control", 1, "off")]),
        ])
        #expect(trials.values == ["slackThing": true, "prefetchThing": false])
        let list = FeatureList(registry: Self.registry, channel: .nightly, overrides: FeatureOverrides(fieldTrial: trials.values))
        #expect(trials.inEffect(in: list).map(\.description) == ["zStudy=treatment", "aStudy=control"])
        #expect(trials.inEffect(in: list).map(\.fieldTag) == ["slackThing=on", "prefetchThing=off"])
    }

    /// An install whose study feature a higher input forces runs that input's value, not its arm's, so its
    /// field data must not count in the arm (base/feature_list.cc activates a trial only when its override is used).
    @Test func aHigherInputOnTheStudysFeatureRemovesItsTrial() {
        let trials = Self.trials([Self.study(arms: [("treatment", 1, "on")])])
        let forced: [(String, FeatureList)] = [
            ("policy", FeatureList(registry: Self.registry, channel: .nightly,
                                   overrides: FeatureOverrides(policyDisabled: ["slackThing"], fieldTrial: trials.values))),
            ("env off", FeatureList(registry: Self.registry, channel: .nightly,
                                    overrides: FeatureOverrides(environmentDisabled: ["slackThing"], fieldTrial: trials.values))),
            ("env on", FeatureList(registry: Self.registry, channel: .nightly,
                                   overrides: FeatureOverrides(environmentEnabled: ["slackThing"], fieldTrial: trials.values))),
            ("remote", FeatureList(registry: Self.registry, channel: .nightly,
                                   overrides: FeatureOverrides(remote: ["slackThing": true], fieldTrial: trials.values))),
            ("local", FeatureList(registry: Self.registry, channel: .nightly,
                                  overrides: FeatureOverrides(fieldTrial: trials.values),
                                  local: FeatureLocalOverrides(values: ["slackThing": true]))),
        ]
        for (input, list) in forced {
            #expect(trials.inEffect(in: list).isEmpty, "\(input) decides slackThing, so its trial is not in effect")
        }
        let list = FeatureList(registry: Self.registry, channel: .nightly, overrides: FeatureOverrides(fieldTrial: trials.values))
        #expect(trials.inEffect(in: list).map(\.study) == ["slackStudy"])
        // A late Debug tunable is the local step too, on NIGHTLY.
        #expect(trials.inEffect(in: list, localOverride: { $0.name == "slackThing" ? true : nil }).isEmpty)
        #expect(trials.inEffect(in: list, localOverride: { $0.name == "prefetchThing" ? false : nil }).map(\.study) == ["slackStudy"])
    }

    @Test func studiesComeFromTheSignedDocument() throws {
        let json = Data("""
        { "version": 1,
          "default": { "FeaturesSerial": 3,
                       "Studies": [ { "name": "slackStudy", "feature": "slackThing", "max_build": 1600,
                                      "arms": [ { "name": "on", "weight": 50, "state": "on" },
                                                { "name": "off", "weight": 50, "state": "off" } ] } ] } }
        """.utf8)
        let document = try FeatureRemoteDocument(json: json, cohort: FeatureRemoteDocument.defaultCohort)
        let overrides = try FeatureRemoteOverrides(document, context: FeatureRemoteContext(registry: Self.registry, build: 1500), now: Date())
        let trials = FieldTrials(studies: overrides.studies, registry: Self.registry, entropy: Self.entropy(1234), channel: .nightly, build: 1500)
        #expect(trials.active.map(\.study) == ["slackStudy"])
        let later = FieldTrials(studies: overrides.studies, registry: Self.registry, entropy: Self.entropy(1234), channel: .nightly, build: 1601)
        #expect(later.active.isEmpty)
    }

    // MARK: The stored value

    private final class Folder: Sendable {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "low-entropy-\(UUID().uuidString)", directoryHint: .isDirectory)
        let work = BackgroundWork(label: "test.low-entropy")
        deinit { try? FileManager.default.removeItem(at: url) }
    }

    @Test func theValueIsDrawnOnceAndKept() async {
        let folder = Folder()
        let first = await LowEntropySource.load(directory: folder.url, work: folder.work, generate: { Self.entropy(42) })
        let second = await LowEntropySource.load(directory: folder.url, work: folder.work, generate: { Self.entropy(7) })
        #expect(first.value == 42)
        #expect(second.value == 42)
    }

    @Test func anOutOfRangeFileIsDrawnAgainAndReported() async throws {
        let folder = Folder()
        try FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: true)
        let file = folder.url.appending(path: LowEntropySource.fileName, directoryHint: .notDirectory)
        try Data(#"{"lowEntropySource": 9000}"#.utf8).write(to: file)
        let lines = Lines()
        let source = await LowEntropySource.load(directory: folder.url, work: folder.work, generate: { Self.entropy(5) },
                                                 report: { lines.append($0) })
        #expect(source.value == 5)
        #expect(lines.all.count == 1)
        #expect(lines.all.first?.contains("outside 0 ..< 8000") == true)
        let again = await LowEntropySource.load(directory: folder.url, work: folder.work, generate: { Self.entropy(6) })
        #expect(again.value == 5)
    }

    /// The report sink's lines.
    private final class Lines: Sendable {
        // concurrency-allow: test sink, appended by load's caller after its await and read after it (lock carve-out: an array, no I/O under it).
        private let lines = Mutex<[String]>([])
        func append(_ line: String) { lines.withLock { $0.append(line) } }
        var all: [String] { lines.withLock { $0 } }
    }
}

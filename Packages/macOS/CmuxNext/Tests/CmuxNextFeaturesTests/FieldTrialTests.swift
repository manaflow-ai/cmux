import CmuxNextCompat
import CmuxNextFeatures
import Foundation
import Testing

/// Nightly field trials (p12-perf-process task 152): the arm a fixed low
/// entropy value picks, the shares over all 8000 values, the study filters,
/// the `Studies` wire form and the stored entropy.
struct FieldTrialTests {
    private static let trial = feature(0, "trialThing", .perfPath)
    private static let other = feature(1, "otherThing", .perfPath)
    private static let kill = feature(2, "killThing", .killSwitch)
    private static let registry = FeatureRegistry([trial, other, kill])

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

    private static func halves(
        _ name: String = "trialThing",
        feature: String = "trialThing",
        channels: Set<Feature.Channel> = FieldTrialStudy.defaultChannels,
        minBuild: String? = nil,
        maxBuild: String? = nil
    ) throws -> FieldTrialStudy {
        try FieldTrialStudy(
            name: name,
            feature: feature,
            arms: [.init(name: "on", weight: 50, isEnabled: true), .init(name: "control", weight: 50, isEnabled: false)],
            channels: channels,
            minBuild: minBuild,
            maxBuild: maxBuild
        )
    }

    private static func entropy(_ value: Int) throws -> LowEntropySource {
        try #require(LowEntropySource(value))
    }

    // MARK: Arm choice

    @Test func murmurHashMatchesTheReferenceVectors() {
        #expect(FieldTrialStudy.murmurHash3([], seed: 0) == 0)
        #expect(FieldTrialStudy.murmurHash3([], seed: 1) == 0x514e_28b7)
        #expect(FieldTrialStudy.murmurHash3(Array("abc".utf8), seed: 0) == 0xb3dd_93fa)
        #expect(FieldTrialStudy.murmurHash3(Array("test".utf8), seed: 0) == 0xba6b_d213)
        #expect(FieldTrialStudy.murmurHash3(Array("Hello, world!".utf8), seed: 1234) == 0xfaf6_cdb3)
        #expect(FieldTrialStudy.murmurHash3(Array("The quick brown fox jumps over the lazy dog".utf8), seed: 0x9747_b28c) == 0x2fa8_26cd)
    }

    /// Goldens from an independent Python MurmurHash3 (x86 32) of the same rule.
    @Test func aFixedEntropyAlwaysPicksTheSameArm() throws {
        let study = try Self.halves()
        let zero = try Self.entropy(0)
        let one = try Self.entropy(1)
        let fortyTwo = try Self.entropy(42)
        #expect(study.seed == 0x6bf8_d955)
        #expect(study.ordinal(of: zero) == 7610)
        #expect(study.ordinal(of: one) == 3026)
        for _ in 0..<3 {
            #expect(study.arm(for: zero).name == "control")
            #expect(study.arm(for: one).name == "on")
            #expect(study.arm(for: fortyTwo).name == "on")
        }
        let renamed = try Self.halves("cefLayerHosting-1")
        #expect(renamed.seed == 0x8f81_92af)
        #expect(renamed.arm(for: zero).name == "on")
        #expect(renamed.arm(for: one).name == "control")
    }

    @Test(arguments: [[50, 50], [10, 30, 60], [1, 99], [33, 33, 34], [7, 0, 3]])
    func sharesAreWithinOnePercentOverEveryValue(weights: [Int]) throws {
        let arms = weights.enumerated().map { FieldTrialStudy.Arm(name: "arm\($0.offset)", weight: $0.element, isEnabled: $0.offset == 0) }
        let study = try FieldTrialStudy(name: "shares\(weights.count)", feature: "trialThing", arms: arms)
        let table = study.armsByEntropy()
        let total = Double(weights.reduce(0, +))
        for (index, weight) in weights.enumerated() {
            let share = Double(table.filter { $0.name == "arm\(index)" }.count) / Double(LowEntropySource.range)
            #expect(abs(share - Double(weight) / total) <= 0.01, "arm\(index): \(share)")
        }
        for value in stride(from: 0, to: LowEntropySource.range, by: 997) {
            let entropy = try Self.entropy(value)
            #expect(study.arm(for: entropy) == table[value])
        }
    }

    @Test func twoStudiesSplitIndependently() throws {
        let first = try Self.halves().armsByEntropy()
        let second = try Self.halves("otherStudy", feature: "otherThing").armsByEntropy()
        let both = zip(first, second).filter { $0.name == "on" && $1.name == "on" }.count
        #expect(abs(Double(both) / Double(LowEntropySource.range) - 0.25) <= 0.02)
    }

    // MARK: Filters

    @Test func maxBuildExcludesLaterBuilds() throws {
        let study = try Self.halves(minBuild: "1200", maxBuild: "1300")
        #expect(study.exclusion(channel: .nightly, build: "1300") == nil)
        #expect(study.exclusion(channel: .nightly, build: "1200") == nil)
        #expect(study.exclusion(channel: .nightly, build: "1301") == .aboveMaxBuild)
        #expect(study.exclusion(channel: .nightly, build: "12000") == .aboveMaxBuild)
        #expect(study.exclusion(channel: .nightly, build: "999") == .belowMinBuild)
        let trials = try FieldTrials(studies: [study], registry: Self.registry, channel: .nightly, build: "1301", entropy: Self.entropy(1))
        #expect(trials.active.isEmpty)
        #expect(trials.excluded == ["trialThing": .aboveMaxBuild])
        #expect(trials.featureStates.isEmpty)
    }

    @Test func releaseIgnoresStudiesThatDoNotNameIt() throws {
        let nightlyOnly = try Self.halves()
        let named = try Self.halves("releaseStudy", feature: "otherThing", channels: [.nightly, .release])
        let trials = try FieldTrials(studies: [nightlyOnly, named], registry: Self.registry, channel: .release, build: "1", entropy: Self.entropy(1))
        #expect(trials.active.map(\.study) == ["releaseStudy"])
        #expect(trials.excluded == ["trialThing": .channel])
    }

    @Test func activeArmsFeedTheFeatureListAndTheReport() throws {
        let trials = try FieldTrials(
            studies: [Self.halves(), Self.halves("otherStudy", feature: "otherThing")],
            registry: Self.registry,
            channel: .nightly,
            build: "1250",
            entropy: Self.entropy(1)
        )
        #expect(trials.featureStates == ["trialThing": true, "otherThing": false])
        #expect(trials.reportEntries == ["otherStudy=control", "trialThing=on"])
        let list = FeatureList(registry: Self.registry, channel: .nightly, overrides: FeatureOverrides(fieldTrial: trials.featureStates))
        #expect(list.resolution(of: Self.trial) == Feature.Resolution(isEnabled: true, source: .fieldTrial))
        #expect(list.resolution(of: Self.other) == Feature.Resolution(isEnabled: false, source: .fieldTrial))
    }

    @Test func badStudiesAreRejectedWithAReason() throws {
        let trials = try FieldTrials(
            studies: [
                Self.halves(),
                Self.halves(),
                Self.halves("sameFeature"),
                Self.halves("killStudy", feature: "killThing"),
                Self.halves("ghost", feature: "noSuchThing"),
            ],
            registry: Self.registry,
            channel: .nightly,
            build: "1",
            entropy: Self.entropy(0)
        )
        #expect(trials.active.map(\.study) == ["trialThing"])
        #expect(trials.rejected.map(\.error) == [
            .duplicateStudy("trialThing"),
            .featureInTwoStudies(feature: "trialThing", first: "trialThing"),
            .notPerfPath("killThing"),
            .unknownFeature("noSuchThing"),
        ])
    }

    @Test func forcedArmsWinAndRunWithoutEntropy() throws {
        let forced = FieldTrials.forcedArms(in: [FieldTrials.forceVariable: " trialThing/control , missing/on, otherStudy/nope,bare"])
        #expect(forced == ["trialThing": "control", "missing": "on", "otherStudy": "nope", "bare": ""])
        let trials = try FieldTrials(
            studies: [Self.halves(), Self.halves("otherStudy", feature: "otherThing")],
            registry: Self.registry,
            channel: .nightly,
            build: "1",
            entropy: nil,
            forced: forced
        )
        #expect(trials.active == [.init(study: "trialThing", feature: "trialThing", arm: "control", isEnabled: false, isForced: true)])
        #expect(trials.rejected.map(\.error) == [.forcedArmUnknown("nope"), .forcedStudyUnknown("bare"), .forcedStudyUnknown("missing")])
    }

    // MARK: Wire form

    @Test func theStudiesListDecodesAndKeepsGoodEntries() throws {
        let json = """
        [
          {"name": "trialThing", "feature": "trialThing", "channel": "nightly", "min_build": "1200", "max_build": 1300,
           "arms": [{"name": "on", "weight": 50, "state": "on"}, {"name": "control", "weight": 50, "state": "off"}]},
          {"feature": "otherThing", "channel": ["nightly", "release"], "arms": [{"name": "on", "weight": 1, "state": "on"}]},
          {"feature": "x", "channel": "beta", "arms": [{"name": "on", "weight": 1, "state": "on"}]},
          {"feature": "y", "arms": [{"name": "on", "weight": 1, "state": "maybe"}]},
          {"feature": "z", "arms": [{"name": "on", "weight": 0, "state": "on"}]},
          {"feature": "w", "arms": [{"name": "a", "weight": 1, "state": "on"}, {"name": "a", "weight": 1, "state": "off"}]},
          {"name": "noFeature", "arms": []},
          {"feature": "v", "min_build": "12a", "arms": [{"name": "on", "weight": 1, "state": "on"}]},
          7
        ]
        """
        let (studies, rejected) = FieldTrialStudy.decodeList(Data(json.utf8))
        #expect(studies.count == 2)
        let first = try Self.halves(minBuild: "1200", maxBuild: "1300")
        #expect(studies.first == first)
        #expect(studies.last?.name == "otherThing")
        #expect(studies.last?.channels == [.nightly, .release])
        #expect(rejected.map(\.study) == ["x", "y", "z", "w", "noFeature", "v", nil])
        #expect(rejected.prefix(6).map(\.error) == [
            .unknownChannel("beta"), .invalidState(arm: "on"), .zeroTotalWeight, .duplicateArm("a"),
            .malformed("feature: missing"), .invalidBuild("12a"),
        ])
        #expect(FieldTrialStudy.decodeList(Data(#"{"a": 1}"#.utf8)).rejected.count == 1)
    }

    @Test func checkedStudiesRefuseBadInput() {
        #expect(throws: FieldTrialError.noArms) { _ = try FieldTrialStudy(feature: "trialThing", arms: []) }
        #expect(throws: FieldTrialError.invalidName("a b")) {
            _ = try FieldTrialStudy(name: "a b", feature: "trialThing", arms: [.init(name: "on", weight: 1, isEnabled: true)])
        }
        #expect(throws: FieldTrialError.invalidWeight(arm: "on")) {
            _ = try FieldTrialStudy(feature: "trialThing", arms: [.init(name: "on", weight: -1, isEnabled: true)])
        }
        #expect(throws: FieldTrialError.noChannel) {
            _ = try FieldTrialStudy(feature: "trialThing", arms: [.init(name: "on", weight: 1, isEnabled: true)], channels: [])
        }
    }

    // MARK: Low entropy source

    @Test func theEntropyRangeIsChecked() {
        #expect(LowEntropySource(0)?.value == 0)
        #expect(LowEntropySource(7999)?.value == 7999)
        #expect(LowEntropySource(8000) == nil)
        #expect(LowEntropySource(-1) == nil)
        #expect(LowEntropySource(storedText: " 123\n")?.value == 123)
        #expect(LowEntropySource(storedText: "9000") == nil)
        #expect(LowEntropySource(storedText: "abc") == nil)
    }

    @Test func theEntropyIsStoredOnceAndReadBack() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("field-trial-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.checked.removeItem(at: folder) }
        let store = LowEntropySource.FileStore(url: folder.appendingPathComponent("nested/low-entropy-source"))
        var generator = SeededGenerator(seed: 7)
        let first = try LowEntropySource.loadOrCreate(from: store, using: &generator)
        for _ in 0..<3 {
            var other = SeededGenerator(seed: 99)
            let again = try LowEntropySource.loadOrCreate(from: store, using: &other)
            #expect(again == first)
        }
        let stored = try store.load()
        #expect(stored == first.description + "\n")
    }

    @Test func aStoredValueOutOfRangeIsReplaced() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("field-trial-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.checked.removeItem(at: folder) }
        let store = LowEntropySource.FileStore(url: folder.appendingPathComponent("low-entropy-source"))
        try store.save("12345")
        var generator = SeededGenerator(seed: 3)
        let created = try LowEntropySource.loadOrCreate(from: store, using: &generator)
        let stored = try store.load()
        #expect(stored == created.description + "\n")
    }

    @Test func aStoreThatCannotSaveThrows() {
        #expect(throws: LowEntropySourceError.saveFailed("disk full")) {
            var generator = SeededGenerator(seed: 1)
            _ = try LowEntropySource.loadOrCreate(from: UnsavableStore(), using: &generator)
        }
    }
}

/// A store with nothing stored that cannot save.
private struct UnsavableStore: LowEntropySourceStore {
    func load() throws(LowEntropySourceError) -> String? { nil }

    func save(_ text: String) throws(LowEntropySourceError) {
        throw LowEntropySourceError.saveFailed("disk full")
    }
}

/// SplitMix64: a repeatable generator for tests.
private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9e37_79b9_7f4a_7c15
        var value = state
        value = (value ^ (value >> 30)) &* 0xbf58_476d_1ce4_e5b9
        value = (value ^ (value >> 27)) &* 0x94d0_49bb_1331_11eb
        return value ^ (value >> 31)
    }
}

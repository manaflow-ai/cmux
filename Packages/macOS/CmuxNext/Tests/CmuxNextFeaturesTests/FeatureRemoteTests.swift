import CmuxNextCompat
import CmuxNextFeatures
import CmuxNextWakeups
import Foundation
import Testing
#if canImport(CryptoKit)
import CryptoKit
#endif

/// The signed flags document's feature keys and the store of its copies
/// (p12-perf-process.md section 3.9, task p12-perf-process-092).
struct FeatureRemoteTests {
    private static let kill = feature(0, "killThing", .killSwitch)
    private static let perf = feature(1, "perfThing", .perfPath)
    private static let registry = FeatureRegistry([kill, perf])
    private static let work = BackgroundWork(label: "test.feature-remote")
    private static let key = "content-key"

    private static func feature(_ index: Int, _ name: String, _ kind: Feature.Kind) -> Feature {
        Feature(
            index: index,
            name: name,
            owner: "PL-test",
            description: "A test feature.",
            kind: kind,
            process: .app,
            chromiumFeature: nil,
            defaults: FeatureDefaults(all: true),
            expires: nil,
            params: [],
            stories: [],
            sticky: false,
            runtimeMutable: false
        )
    }

    /// A stand-in for `ContentSignature.verify`: a signature is the key and the bytes, so any changed byte fails.
    private static func fakeVerify(_ data: Data, _ signature: String, _ publicKey: String) -> Bool {
        signature == fakeSign(data, key: publicKey)
    }

    private static func fakeSign(_ data: Data, key: String = key) -> String {
        "\(key):\(data.base64EncodedString())"
    }

    private static func copy(_ json: String, key: String = key) -> FeatureRemoteStore.Copy {
        let data = Data(json.utf8)
        return FeatureRemoteStore.Copy(data: data, signature: fakeSign(data, key: key))
    }

    /// A store in a fresh directory, and the lines it reported.
    private final class Harness: Sendable {
        let store: FeatureRemoteStore
        private let lines: LockedLines

        init(build: UInt64? = 100, cohort: String = FeatureRemoteDocument.defaultCohort, now: Date = Date(timeIntervalSince1970: 1_800_000_000)) {
            let directory = FileManager.default.temporaryDirectory
                .appending(path: "feature-remote-\(UUID().uuidString)", directoryHint: .isDirectory)
            let lines = LockedLines()
            self.lines = lines
            store = FeatureRemoteStore(
                directory: directory,
                context: FeatureRemoteContext(registry: FeatureRemoteTests.registry, cohort: cohort, build: build),
                work: FeatureRemoteTests.work,
                signatures: FeatureRemoteSignatureCheck(contentSigningKey: FeatureRemoteTests.key, verify: FeatureRemoteTests.fakeVerify),
                now: { now },
                report: { lines.append($0) }
            )
        }

        var reported: [String] { lines.all }

        deinit { try? FileManager.default.removeItem(at: store.directory) }
    }

    /// The report sink's lines; the store reports from its own tasks.
    private final class LockedLines: Sendable {
        // concurrency-allow: test sink, appended by the store's caller and read after its awaits (lock carve-out: an array, no I/O under it).
        private let lines = Mutex<[String]>([])
        func append(_ line: String) { lines.withLock { $0.append(line) } }
        var all: [String] { lines.withLock { $0 } }
    }

    // MARK: Parse

    @Test func aCohortKeyReplacesTheDefaultKey() throws {
        let json = """
        {"version": 1,
         "default": {"Features": {"killThing": "off", "perfThing": "on"}, "FeaturesSerial": 3, "FeaturesMaxBuild": 200},
         "cohorts": {"wave-1": {"Features": {"perfThing": "off"}, "FeaturesSerial": 4}}}
        """
        let wave = try FeatureRemoteDocument(json: Data(json.utf8), cohort: "wave-1")
        #expect(wave.features == ["perfThing": "off"])
        #expect(wave.serial == 4)
        #expect(wave.maxBuild == 200)
        let everyone = try FeatureRemoteDocument(json: Data(json.utf8), cohort: "other")
        #expect(everyone.features == ["killThing": "off", "perfThing": "on"])
        #expect(everyone.serial == 3)
    }

    @Test func todaysDocumentHasNoOverrides() throws {
        let document = try FeatureRemoteDocument(json: Data(#"{"version": 1, "default": {}, "cohorts": {}}"#.utf8), cohort: "default")
        #expect(document == FeatureRemoteDocument(serial: 0))
        let overrides = try FeatureRemoteOverrides(document, context: FeatureRemoteContext(registry: Self.registry, build: nil), now: Date())
        #expect(overrides == FeatureRemoteOverrides.none)
    }

    @Test func aDocumentOfAnotherVersionOrWithoutASerialIsRefused() {
        #expect(throws: FeatureRemoteDocumentError.unsupportedVersion(2)) {
            try FeatureRemoteDocument(json: Data(#"{"version": 2, "default": {}}"#.utf8), cohort: "default")
        }
        #expect(throws: FeatureRemoteDocumentError.missingSerial) {
            try FeatureRemoteDocument(json: Data(#"{"version": 1, "default": {"Features": {"killThing": "off"}}}"#.utf8), cohort: "default")
        }
    }

    @Test func studiesAreParsedAndAStudyOfAnUnknownFeatureIsIgnored() throws {
        let json = """
        {"version": 1, "default": {"FeaturesSerial": 1, "Studies": [
          {"name": "s1", "feature": "perfThing", "channel": "nightly", "min_build": 10, "max_build": 20,
           "arms": [{"name": "on", "weight": 50, "state": "on"}, {"name": "off", "weight": 50, "state": "off"}]},
          {"name": "s2", "feature": "gone", "arms": []}]}}
        """
        let document = try FeatureRemoteDocument(json: Data(json.utf8), cohort: "default")
        let overrides = try FeatureRemoteOverrides(document, context: FeatureRemoteContext(registry: Self.registry, build: 15), now: Date())
        #expect(overrides.studies.map(\.name) == ["s1"])
        #expect(overrides.studies.first?.arms.map(\.weight) == [50, 50])
        #expect(overrides.studies.first?.minBuild == 10)
        #expect(overrides.ignored == [.unknownStudyFeature(study: "s2", feature: "gone")])
    }

    // MARK: Filters

    @Test func anUnknownNameIsIgnoredAndLogged() async throws {
        let harness = Harness()
        let overrides = try await harness.store.store(Self.copy("""
        {"version": 1, "default": {"Features": {"killThing": "off", "noSuchFeature": "off", "perfThing": "maybe"}, "FeaturesSerial": 1}}
        """))
        #expect(overrides.values == ["killThing": false])
        #expect(overrides.ignored == [.unknownFeature("noSuchFeature"), .badValue(feature: "perfThing", value: "maybe")])
        #expect(harness.reported.contains("flags document entry ignored: unknown feature noSuchFeature"))
        let list = FeatureList(registry: Self.registry, channel: .release, overrides: FeatureOverrides(remote: overrides.values))
        #expect(list.resolution(of: Self.kill) == Feature.Resolution(isEnabled: false, source: .remote))
        #expect(list.unknownNames.isEmpty)
    }

    @Test func aLowerSerialIsIgnored() async throws {
        let harness = Harness()
        try await harness.store.store(Self.copy(#"{"version": 1, "default": {"Features": {"killThing": "off"}, "FeaturesSerial": 5}}"#))
        await #expect(throws: FeatureRemoteStore.WriteError.rejected(.lowerSerial(document: 4, stored: 5))) {
            try await harness.store.store(Self.copy(#"{"version": 1, "default": {"Features": {"killThing": "on"}, "FeaturesSerial": 4}}"#))
        }
        let launch = await harness.store.load()
        #expect(launch.last?.document.serial == 5)
        #expect(harness.store.overrides(of: launch.last).values == ["killThing": false])
        // The same serial again (a re-fetch) is accepted.
        try await harness.store.store(Self.copy(#"{"version": 1, "default": {"Features": {"killThing": "off"}, "FeaturesSerial": 5}}"#))
    }

    @Test func maxBuildExcludesLaterBuilds() async throws {
        let json = #"{"version": 1, "default": {"Features": {"killThing": "off"}, "FeaturesSerial": 1, "FeaturesMinBuild": 90, "FeaturesMaxBuild": 100}}"#
        let later = Harness(build: 101)
        await #expect(throws: FeatureRemoteStore.WriteError.rejected(.buildAboveMaximum(build: 101, maximum: 100))) {
            try await later.store.store(Self.copy(json))
        }
        #expect(await later.store.load().last == nil)
        let earlier = Harness(build: 89)
        await #expect(throws: FeatureRemoteStore.WriteError.rejected(.buildBelowMinimum(build: 89, minimum: 90))) {
            try await earlier.store.store(Self.copy(json))
        }
        let unnumbered = Harness(build: nil)
        await #expect(throws: FeatureRemoteStore.WriteError.rejected(.buildUnknown)) {
            try await unnumbered.store.store(Self.copy(json))
        }
        let inRange = Harness(build: 100)
        #expect(try await inRange.store.store(Self.copy(json)).values == ["killThing": false])

        // A copy stored by build 100 gives nothing once the app updates past the range.
        let stored = try #require(await inRange.store.load().last)
        let updated = FeatureRemoteContext(registry: Self.registry, build: 101)
        #expect(throws: FeatureRemoteDocumentError.buildAboveMaximum(build: 101, maximum: 100)) {
            try FeatureRemoteOverrides(stored.document, context: updated, now: Date())
        }
    }

    @Test func anExpiredDocumentGivesNothing() async throws {
        // 2027-01-15T08:00:00Z is 1_800_000_000 s after the epoch.
        let json = #"{"version": 1, "default": {"Features": {"killThing": "off"}, "FeaturesSerial": 1, "FeaturesExpiresAt": "2027-01-15T08:00:00Z"}}"#
        let before = Harness(now: Date(timeIntervalSince1970: 1_700_000_000))
        #expect(try await before.store.store(Self.copy(json)).values == ["killThing": false])
        let after = Harness(now: Date(timeIntervalSince1970: 1_900_000_000))
        await #expect(throws: FeatureRemoteStore.WriteError.rejected(.expired(at: Date(timeIntervalSince1970: 1_800_000_000)))) {
            try await after.store.store(Self.copy(json))
        }
    }

    // MARK: Signatures and copies

    @Test func aTamperedByteIsRefusedOnStoreAndOnLoad() async throws {
        let harness = Harness()
        var tampered = Self.copy(#"{"version": 1, "default": {"Features": {"killThing": "off"}, "FeaturesSerial": 1}}"#)
        tampered = FeatureRemoteStore.Copy(data: tampered.data + Data(" ".utf8), signature: tampered.signature)
        await #expect(throws: FeatureRemoteStore.WriteError.rejected(.badSignature)) {
            try await harness.store.store(tampered)
        }

        try await harness.store.store(Self.copy(#"{"version": 1, "default": {"Features": {"killThing": "off"}, "FeaturesSerial": 1}}"#))
        let file = harness.store.files(.last).data
        let edited = try String(contentsOf: file, encoding: .utf8).replacingOccurrences(of: "\"off\"", with: "\"on\"")
        try Data(edited.utf8).write(to: file)
        #expect(await harness.store.load().last == nil)
        #expect(harness.reported.contains { $0.contains("does not verify") })
    }

    @Test func theLastKnownGoodCopyIsKeptApart() async throws {
        let harness = Harness()
        let good = Self.copy(#"{"version": 1, "default": {"Features": {"killThing": "off"}, "FeaturesSerial": 1}}"#)
        try await harness.store.store(good)
        try await harness.store.promoteLastKnownGood(good)
        try await harness.store.store(Self.copy(#"{"version": 1, "default": {"Features": {"perfThing": "off"}, "FeaturesSerial": 2}}"#))
        let launch = await harness.store.load()
        #expect(launch.last?.document.serial == 2)
        #expect(launch.lastKnownGood?.copy == good)
        #expect(harness.store.overrides(of: launch.lastKnownGood).values == ["killThing": false])
        await #expect(throws: FeatureRemoteStore.WriteError.rejected(.badSignature)) {
            try await harness.store.promoteLastKnownGood(FeatureRemoteStore.Copy(data: good.data, signature: "forged"))
        }
    }

    @Test func noStoredCopyLoadsAsNone() async {
        let harness = Harness()
        let launch = await harness.store.load()
        #expect(launch == FeatureRemoteStore.Launch(last: nil, lastKnownGood: nil))
        #expect(harness.store.overrides(of: launch.last) == .none)
        #expect(harness.reported.isEmpty)
    }

    // MARK: The bench test key

    @Test func theTestKeyIsTrustedOnlyInBenchBuilds() throws {
        let check = FeatureRemoteSignatureCheck(contentSigningKey: Self.key, verify: Self.fakeVerify)
        let data = Data("{}".utf8)
        #if CMUX_BENCH_HOOKS
        let testKey = try #require(FeatureRemoteSignatureCheck.benchTestPublicKey)
        #expect(check.publicKeys == [Self.key, testKey])
        #expect(check.isValid(data, signature: Self.fakeSign(data, key: testKey)))
        #else
        // A Release (and every non-bench) build compiles no test key.
        #expect(FeatureRemoteSignatureCheck.benchTestPublicKey == nil)
        #expect(check.publicKeys == [Self.key])
        #expect(!check.isValid(data, signature: Self.fakeSign(data, key: Self.committedTestKey.publicKey)))
        #endif
        #expect(check.isValid(data, signature: " \(Self.fakeSign(data))\n"))
    }

    /// `schemas/features/bench-test-signing-key.json`, read by path from the checkout.
    private static var committedTestKey: (publicKey: String, privateSeed: String) {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appending(path: "schemas/features/bench-test-signing-key.json")
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let publicKey = object["publicKey"], let privateSeed = object["privateSeed"]
        else { return ("missing \(url.path)", "") }
        return (publicKey, privateSeed)
    }

    #if canImport(CryptoKit)
    /// The committed private seed signs what the compiled bench key verifies, and only a bench build trusts it.
    @Test func theCommittedTestKeySignsForTheBenchKey() throws {
        let committed = Self.committedTestKey
        let seed = try #require(Data(base64Encoded: committed.privateSeed))
        let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
        #expect(privateKey.publicKey.rawRepresentation.base64EncodedString() == committed.publicKey)
        let data = Data(#"{"version": 1, "default": {"Features": {"killThing": "off"}, "FeaturesSerial": 1}}"#.utf8)
        let signature = try privateKey.signature(for: data).base64EncodedString()
        let check = FeatureRemoteSignatureCheck(contentSigningKey: Self.key) { data, signature, key in
            guard let signature = Data(base64Encoded: signature), let key = Data(base64Encoded: key),
                  let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: key) else { return false }
            return publicKey.isValidSignature(signature, for: data)
        }
        #if CMUX_BENCH_HOOKS
        #expect(FeatureRemoteSignatureCheck.benchTestPublicKey == committed.publicKey)
        #expect(check.isValid(data, signature: signature))
        #else
        #expect(!check.isValid(data, signature: signature))
        #endif
    }
    #endif
}

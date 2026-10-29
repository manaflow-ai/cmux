import CmuxNextCompat
import CmuxNextFeatures
import CmuxNextWakeups
import Foundation
import Testing
#if canImport(CryptoKit)
import CryptoKit
#endif

/// The signed flags document's feature keys and the store of its copies
/// (p12-perf-process.md section 3.9).
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

    /// The committed `release-notes/next/flags.json` parses (it has the serial `nightly.yml` asserts) and overrides nothing.
    @Test func theCommittedTemplateHasNoOverrides() throws {
        let url = Self.repositoryRoot.appending(path: "release-notes/next/flags.json")
        let document = try FeatureRemoteDocument(json: try Data(contentsOf: url), cohort: "default")
        #expect(document.features.isEmpty && document.studies.isEmpty)
        let overrides = try FeatureRemoteOverrides(document, context: FeatureRemoteContext(registry: Self.registry, build: nil), now: Date())
        #expect(overrides.values.isEmpty && overrides.studies.isEmpty)
    }

    @Test func aDocumentOfAnotherVersionOrWithoutASerialIsRefused() {
        #expect(throws: FeatureRemoteDocumentError.unsupportedVersion(2)) {
            try FeatureRemoteDocument(json: Data(#"{"version": 2, "default": {}}"#.utf8), cohort: "default")
        }
        #expect(throws: FeatureRemoteDocumentError.missingSerial) {
            try FeatureRemoteDocument(json: Data(#"{"version": 1, "default": {"Features": {"killThing": "off"}}}"#.utf8), cohort: "default")
        }
        // A document with no feature keys needs its serial too, or it could never replace a stored one.
        #expect(throws: FeatureRemoteDocumentError.missingSerial) {
            try FeatureRemoteDocument(json: Data(#"{"version": 1, "default": {}, "cohorts": {}}"#.utf8), cohort: "default")
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
        // A build outside the range stores the document (the newest one decides) and gets nothing from it.
        let later = Harness(build: 101)
        #expect(try await later.store.store(Self.copy(json)) == FeatureRemoteOverrides.none)
        #expect(later.reported.contains("flags document 1 not applied: build 101 is above FeaturesMaxBuild 100"))
        let excluded = try #require(await later.store.load().last)
        #expect(later.store.overrides(of: excluded) == FeatureRemoteOverrides.none)
        let earlier = Harness(build: 89)
        #expect(try await earlier.store.store(Self.copy(json)) == FeatureRemoteOverrides.none)
        #expect(earlier.reported.contains("flags document 1 not applied: build 89 is below FeaturesMinBuild 90"))
        let unnumbered = Harness(build: nil)
        #expect(try await unnumbered.store.store(Self.copy(json)) == FeatureRemoteOverrides.none)
        #expect(unnumbered.reported.contains { $0.hasPrefix("flags document 1 not applied: the document names a build range") })
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
        #expect(try await after.store.store(Self.copy(json)) == FeatureRemoteOverrides.none)
        #expect(await after.store.load().last?.document.serial == 1)
        #expect(after.reported.contains { $0.hasPrefix("flags document 1 not applied: expired at") })
    }

    /// The newest document decides, as Chrome stores the latest seed and filters it when it is used
    /// (components/variations/study_filtering.cc): one that excludes this build takes the older one's overrides back.
    @Test func aNewerDocumentThatExcludesThisBuildTakesTheOverridesBack() async throws {
        let older = #"{"version": 1, "default": {"Features": {"killThing": "off"}, "FeaturesSerial": 7}}"#
        let narrowed = #"{"version": 1, "default": {"Features": {"killThing": "off"}, "FeaturesSerial": 8, "FeaturesMaxBuild": 100}}"#
        let fixed = Harness(build: 101)
        try await fixed.store.store(Self.copy(older))
        #expect(try await fixed.store.store(Self.copy(narrowed)) == FeatureRemoteOverrides.none)
        let launch = await fixed.store.load()
        #expect(launch.last?.document.serial == 8)
        #expect(fixed.store.overrides(of: launch.last) == FeatureRemoteOverrides.none)

        // A build the narrowed range still holds keeps the overrides.
        let old = Harness(build: 99)
        try await old.store.store(Self.copy(older))
        #expect(try await old.store.store(Self.copy(narrowed)).values == ["killThing": false])
    }

    @Test func aNewerDocumentThatHasExpiredTakesTheOverridesBack() async throws {
        // 2027-01-15T08:00:00Z is 1_800_000_000 s after the epoch; the clock reads 1_900_000_000.
        let harness = Harness(now: Date(timeIntervalSince1970: 1_900_000_000))
        try await harness.store.store(Self.copy(#"{"version": 1, "default": {"Features": {"killThing": "off"}, "FeaturesSerial": 5}}"#))
        let expired = #"{"version": 1, "default": {"Features": {"killThing": "off"}, "FeaturesSerial": 6, "FeaturesExpiresAt": "2027-01-15T08:00:00Z"}}"#
        #expect(try await harness.store.store(Self.copy(expired)) == FeatureRemoteOverrides.none)
        let launch = await harness.store.load()
        #expect(launch.last?.document.serial == 6)
        #expect(harness.store.overrides(of: launch.last) == FeatureRemoteOverrides.none)
    }

    /// Ending every override is a document with no `Features` and a higher serial; one with no serial is refused.
    @Test func aDocumentWithNoFeaturesAndAHigherSerialEndsTheOverrides() async throws {
        let harness = Harness()
        try await harness.store.store(Self.copy(#"{"version": 1, "default": {"Features": {"killThing": "off"}, "FeaturesSerial": 5}}"#))
        await #expect(throws: FeatureRemoteStore.WriteError.rejected(.missingSerial)) {
            try await harness.store.store(Self.copy(#"{"version": 1, "default": {}, "cohorts": {}}"#))
        }
        #expect(try await harness.store.store(Self.copy(#"{"version": 1, "default": {"FeaturesSerial": 6}, "cohorts": {}}"#)) == FeatureRemoteOverrides.none)
        let launch = await harness.store.load()
        #expect(launch.last?.document.serial == 6)
        #expect(harness.store.overrides(of: launch.last) == FeatureRemoteOverrides.none)
    }

    // MARK: Order

    /// Stores and loads from tasks of every priority run one at a time in post order:
    /// the highest serial stays and the stored copy always verifies.
    @Test func concurrentStoresAtDifferentPrioritiesKeepTheHighestSerial() async throws {
        let harness = Harness()
        let priorities: [TaskPriority] = [.background, .utility, .medium, .high]
        let serials = UInt64(1)...UInt64(40)
        await withTaskGroup(of: Void.self) { group in
            for serial in serials {
                let copy = Self.copy(#"{"version": 1, "default": {"Features": {"killThing": "off"}, "FeaturesSerial": \#(serial)}}"#)
                group.addTask(priority: priorities[Int(serial) % priorities.count]) {
                    _ = try? await harness.store.store(copy)
                    _ = await harness.store.load()
                }
            }
        }
        let launch = await harness.store.load()
        #expect(launch.last?.document.serial == serials.upperBound)
        #expect(!harness.reported.contains { $0.contains("does not verify") || $0.contains("unreadable") })
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
        try Self.editStoredDocument(harness.store.file(.last)) { $0.replacingOccurrences(of: "\"off\"", with: "\"on\"") }
        #expect(await harness.store.load().last == nil)
        #expect(harness.reported.contains { $0.contains("does not verify") })
    }

    /// A stored copy that does not verify (only a file changed outside the app: a write replaces the
    /// whole file) holds no serial: a lower one replaces it, and the store reports the bad copy.
    @Test func aStoredCopyThatDoesNotVerifyHoldsNoSerial() async throws {
        let harness = Harness()
        try await harness.store.store(Self.copy(#"{"version": 1, "default": {"Features": {"killThing": "off"}, "FeaturesSerial": 5}}"#))
        try Self.editStoredDocument(harness.store.file(.last)) { $0.replacingOccurrences(of: "\"off\"", with: "\"on\"") }
        try await harness.store.store(Self.copy(#"{"version": 1, "default": {"Features": {"perfThing": "off"}, "FeaturesSerial": 3}}"#))
        #expect(harness.reported.contains("last flags document: the signature does not verify"))
        #expect(await harness.store.load().last?.document.serial == 3)
    }

    /// Changes the document bytes of a stored copy and keeps its signature.
    private static func editStoredDocument(_ file: URL, _ edit: (String) -> String) throws {
        let stored = try JSONDecoder().decode(FeatureRemoteStore.Copy.self, from: Data(contentsOf: file))
        let text = edit(String(decoding: stored.data, as: UTF8.self))
        let edited = FeatureRemoteStore.Copy(data: Data(text.utf8), signature: stored.signature)
        try JSONEncoder().encode(edited).write(to: file)
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
        #expect(harness.store.overrides(of: launch.last) == FeatureRemoteOverrides.none)
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
        // A non-bench test build compiles no test key; check-no-bench-hooks.sh checks the shipped executable.
        #expect(FeatureRemoteSignatureCheck.benchTestPublicKey == nil)
        #expect(check.publicKeys == [Self.key])
        #expect(!check.isValid(data, signature: Self.fakeSign(data, key: Self.committedTestKey.publicKey)))
        #endif
        #expect(check.isValid(data, signature: " \(Self.fakeSign(data))\n"))
    }

    /// The checkout this file is in.
    private static var repositoryRoot: URL {
        URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    /// `schemas/features/bench-test-signing-key.json`, read by path from the checkout.
    private static var committedTestKey: (publicKey: String, privateSeed: String) {
        let url = repositoryRoot.appending(path: "schemas/features/bench-test-signing-key.json")
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
        let data = Data(Self.vectorDocument.utf8)
        let signature = try privateKey.signature(for: data).base64EncodedString()
        let check = FeatureRemoteSignatureCheck(contentSigningKey: Self.key, verify: Self.ed25519Verify)
        #if CMUX_BENCH_HOOKS
        #expect(FeatureRemoteSignatureCheck.benchTestPublicKey == committed.publicKey)
        #expect(check.isValid(data, signature: signature))
        #else
        #expect(!check.isValid(data, signature: signature))
        #endif
    }

    /// The shared vector: `scripts/features/publish-flags.py` signs it with the committed test key through
    /// openssl (`VECTOR_SIGNATURE` in its tests); the daemon's `feature_flags::verify` checks the same bytes.
    private static let vectorDocument = #"{"version": 1, "default": {"Features": {"killThing": "off"}, "FeaturesSerial": 1}}"#
    private static let vectorSignature = "awi7tNpxH9yQKKOTIR0rnhqC9NTbcMynkyHu64U9D1th0EHUG131NFw6LDGVN7gA+hhBDgJJA3xWZUMOv5eDBw=="

    /// What the publish tool signs verifies with the bench key, and a bench build's check accepts it.
    @Test func thePublishToolsVectorVerifiesWithTheBenchKey() {
        let data = Data(Self.vectorDocument.utf8)
        let publicKey = Self.committedTestKey.publicKey
        #expect(Self.ed25519Verify(data, Self.vectorSignature, publicKey))
        #expect(!Self.ed25519Verify(data + Data(" ".utf8), Self.vectorSignature, publicKey))
        let check = FeatureRemoteSignatureCheck(contentSigningKey: Self.key, verify: Self.ed25519Verify)
        #if CMUX_BENCH_HOOKS
        #expect(check.isValid(data, signature: "\(Self.vectorSignature)\n"))
        #else
        #expect(!check.isValid(data, signature: Self.vectorSignature))
        #endif
    }

    /// `ContentSignature.verify`'s check: an Ed25519 signature (base64) of the data by the raw public key (base64).
    private static func ed25519Verify(_ data: Data, _ signature: String, _ key: String) -> Bool {
        guard let signature = Data(base64Encoded: signature), let key = Data(base64Encoded: key),
              let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: key) else { return false }
        return publicKey.isValidSignature(signature, for: data)
    }
    #endif
}

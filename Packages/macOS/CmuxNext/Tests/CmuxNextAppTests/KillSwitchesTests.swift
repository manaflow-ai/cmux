import CmuxNextCompat
import CmuxUpdater
@testable import CmuxNextUpdater
import CryptoKit
import Foundation
import Testing
@MainActor @Suite(.serialized) struct KillSwitchesTests {
    actor Gate {
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private var arrived = 0
        private var arrivals: [(count: Int, waiter: CheckedContinuation<Void, Never>)] = []
        func wait() async {
            arrived += 1
            let reached = arrivals.filter { $0.count <= arrived }
            arrivals.removeAll { $0.count <= arrived }
            reached.forEach { $0.waiter.resume() }
            guard !isOpen else { return }
            await withCheckedContinuation { waiters.append($0) }
        }
        func reached(_ count: Int) async {
            guard arrived < count else { return }
            await withCheckedContinuation { arrivals.append((count, $0)) }
        }
        func release() {
            isOpen = true
            waiters.forEach { $0.resume() }
            waiters = []
        }
    }
    actor Network: AppcastFetching {
        var files: [String: Data]
        var offline = false
        var gate: Gate?
        func hold(_ gate: Gate) { self.gate = gate }
        init(files: [String: Data]) { self.files = files }
        func set(_ files: [String: Data], offline: Bool = false) {
            self.files = files
            self.offline = offline
        }
        func fetch(_ url: URL) async throws -> Data {
            let data = offline ? nil : files[url.lastPathComponent]
            await gate?.wait()
            guard let data else { throw URLError(.fileDoesNotExist) }
            return data
        }
    }
    struct Fixture {
        let key = Curve25519.Signing.PrivateKey()
        let cache = FileManager.default.temporaryDirectory.appending(path: "cnc-kill-switches-\(UUID().uuidString)",
                                                                      directoryHint: .isDirectory)
        func served(_ document: String, signer: Curve25519.Signing.PrivateKey? = nil) throws -> [String: Data] {
            let data = Data(document.utf8)
            let signature = try (signer ?? key).signature(for: data).base64EncodedString()
            return ["flags.json": data, "flags.json.sig": Data(signature.utf8)]
        }
        func store(_ network: Network) throws -> ReleaseNotesStore {
            try #require(ReleaseNotesStore(feedURL: "https://notes.test/nightly-next/next/appcast-arm64.xml", cache: cache,
                                           publicKey: key.publicKey.rawRepresentation.base64EncodedString(), fetcher: network))
        }
        func tearDown() { try? FileManager.default.removeItem(at: cache) }
    }
    static let offPR = #"{"version":1,"default":{"DisabledFeatures":["pr-23456","cloud-vm"]},"cohorts":{}}"#
    @Test func aCohortReplacesTheDefaultList() throws {
        let document = try #require(KillSwitchDocument(data: Data("""
        {"version":1,"default":{"DisabledFeatures":["pr-1","pr-2"]},
         "cohorts":{"dev":{"DisabledFeatures":["pr-3"]},"canary":{"MinimumVersion":"1.0"}}}
        """.utf8)))
        #expect(document.off(cohort: "nightly") == ["pr-1", "pr-2"])
        #expect(document.off(cohort: "dev") == ["pr-3"])
        #expect(document.off(cohort: "canary") == ["pr-1", "pr-2"])
    }
    @Test func onlyPRSwitchesOfAVersionOneDocumentCount() throws {
        let document = try #require(KillSwitchDocument(data: Data(Self.offPR.utf8)))
        #expect(document.off(cohort: "nightly") == ["pr-23456"])
        #expect(KillSwitchDocument(data: Data(#"{"version":2,"default":{"DisabledFeatures":["pr-1"]}}"#.utf8)) == nil)
        #expect(KillSwitchDocument(data: Data("not json".utf8)) == nil)
    }
    @Test func onlyAVerifiedDocumentIsReadAndCached() async throws {
        let fixture = Fixture()
        defer { fixture.tearDown() }
        let network = Network(files: try fixture.served(Self.offPR, signer: Curve25519.Signing.PrivateKey()))
        let store = try fixture.store(network)
        #expect(await store.flags() == nil)
        await network.set(["flags.json": Data(Self.offPR.utf8)])
        #expect(await store.flags() == nil)
        await network.set(try fixture.served(Self.offPR))
        #expect(await store.flags()?.off(cohort: "nightly") == ["pr-23456"])
        await network.set([:], offline: true)
        #expect(await store.flags()?.off(cohort: "nightly") == ["pr-23456"])
        try Data(#"{"version":1,"default":{"DisabledFeatures":["pr-9"]}}"#.utf8).write(to: fixture.cache.appending(path: "flags.json"))
        #expect(await store.flags() == nil)
    }
    static func reader(store: ReleaseNotesStore, switches: KillSwitches) throws -> (UpdaterService, KillSwitchReader) {
        let identity = UpdateBuildIdentity(bundleIdentifier: "com.cmuxterm.app.debug.kill-switches", shortVersion: "1.0.0",
                                           build: "100", minimumSystemVersion: nil,
                                           infoFeedURL: "https://notes.test/nightly-next/next/appcast-arm64.xml", hasPublicKey: false)
        let defaults = try #require(UserDefaults(suiteName: "KillSwitchesTests.\(UUID().uuidString)"))
        let updater = UpdaterService(identity: identity, policy: ManagedUpdatePolicy { false }, defaults: defaults,
                                     enableSparkle: false, recordsUpdates: false)
        updater.announcementsFetch = false
        return (updater, KillSwitchReader(updater: updater, switches: switches) { _ in store })
    }
    @Test func theReaderTurnsOffWhatTheSignedDocumentListsForTheRing() async throws {
        let fixture = Fixture()
        defer { fixture.tearDown() }
        let network = Network(files: try fixture.served(#"""
        {"version":1,"default":{"DisabledFeatures":["pr-23456"]},"cohorts":{"dev":{"DisabledFeatures":["pr-777"]}}}
        """#))
        let switches = KillSwitches()
        let (updater, reader) = try Self.reader(store: try fixture.store(network), switches: switches)
        defer { withExtendedLifetime(updater) {} }
        #expect(!switches.isOff("pr-23456"))
        await reader.read()?.value
        #expect(switches.isOff("pr-23456"))
        #expect(!switches.isOff("pr-777"))
        updater.follow(ring: "dev")
        await reader.read()?.value
        #expect(switches.off == ["pr-777"])
    }
    @Test func aMisSignedDocumentKeepsEveryChangeOn() async throws {
        let fixture = Fixture()
        defer { fixture.tearDown() }
        let network = Network(files: try fixture.served(Self.offPR))
        let switches = KillSwitches()
        let (updater, reader) = try Self.reader(store: try fixture.store(network), switches: switches)
        defer { withExtendedLifetime(updater) {} }
        await reader.read()?.value
        #expect(switches.isOff("pr-23456"))
        await network.set(try fixture.served(#"{"version":1,"default":{"DisabledFeatures":["pr-1"]}}"#,
                                             signer: Curve25519.Signing.PrivateKey()))
        await reader.read()?.value
        #expect(switches.off == ["pr-23456"])
        fixture.tearDown()
        await reader.read()?.value
        #expect(switches.off.isEmpty)
    }
    @Test func aReadForAnotherRingRunsAfterTheOneInFlightAndOnlyItsListApplies() async throws {
        let fixture = Fixture()
        defer { fixture.tearDown() }
        let network = Network(files: try fixture.served(#"""
        {"version":1,"default":{"DisabledFeatures":["pr-1"]},"cohorts":{"dev":{"DisabledFeatures":["pr-2"]}}}
        """#))
        let gate = Gate()
        await network.hold(gate)
        let switches = KillSwitches()
        let (updater, reader) = try Self.reader(store: try fixture.store(network), switches: switches)
        defer { withExtendedLifetime(updater) {} }
        let nightly = try #require(reader.read())
        updater.follow(ring: "dev")
        let joined = try #require(reader.read())
        await gate.release()
        await nightly.value
        #expect(!switches.isOff("pr-1"))
        await joined.value
        #expect(switches.off == ["pr-2"])
    }
    @Test func aReadAskedWhileTheSameRingsFetchIsOutReadsAgainAfterIt() async throws {
        let fixture = Fixture()
        defer { fixture.tearDown() }
        let network = Network(files: try fixture.served(#"{"version":1,"default":{"DisabledFeatures":["pr-1"]}}"#))
        let gate = Gate()
        await network.hold(gate)
        let switches = KillSwitches()
        let (updater, reader) = try Self.reader(store: try fixture.store(network), switches: switches)
        defer { withExtendedLifetime(updater) {} }
        let first = try #require(reader.read())
        await gate.reached(2)
        await network.set(try fixture.served(#"{"version":1,"default":{"DisabledFeatures":["pr-2"]}}"#))
        let asked = try #require(reader.read())
        await gate.release()
        await first.value
        await asked.value
        #expect(switches.off == ["pr-2"])
    }
    @Test func killSwitchReadsTheSharedSwitches() {
        #expect(!killSwitch("pr-999999001"))
        KillSwitches.shared.replace(off: ["pr-999999001"])
        defer { KillSwitches.shared.replace(off: []) }
        #expect(killSwitch("pr-999999001"))
    }
}

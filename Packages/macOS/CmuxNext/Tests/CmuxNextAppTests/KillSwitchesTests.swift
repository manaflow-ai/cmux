import CmuxNextCompat
import CmuxUpdater
@testable import CmuxNextUpdater
import CryptoKit
import Foundation
import Testing

/// Per-PR kill switches (leo-workspace briefs/2026-10-20-gui-push/partial-rollback.md, section 2):
/// the signed `notes/flags.json` next to the feed lists `pr-N` switches to turn off; nothing else
/// does. A missing, unsigned or mis-signed document turns nothing off, so a PR's change ships.
@MainActor @Suite(.serialized) struct KillSwitchesTests {
    /// Holds requests until released.
    actor Gate {
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            guard !isOpen else { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func release() {
            isOpen = true
            waiters.forEach { $0.resume() }
            waiters = []
        }
    }

    /// A notes server that answers the files it holds; `offline` answers nothing; `gate` holds requests.
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

        /// Answers what the server held when the request arrived, as a real response does.
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

        /// `flags.json` and its signature by `signer` (the fixture's key unless given).
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
        // A cohort without the key keeps the default's.
        #expect(document.off(cohort: "canary") == ["pr-1", "pr-2"])
    }

    @Test func onlyPRSwitchesOfAVersionOneDocumentCount() throws {
        let document = try #require(KillSwitchDocument(data: Data(Self.offPR.utf8)))
        // cmux-tui's invite-wave features (`cloud-vm`) are not kill switches.
        #expect(document.off(cohort: "nightly") == ["pr-23456"])
        #expect(KillSwitchDocument(data: Data(#"{"version":2,"default":{"DisabledFeatures":["pr-1"]}}"#.utf8)) == nil)
        #expect(KillSwitchDocument(data: Data("not json".utf8)) == nil)
    }

    @Test func onlyAVerifiedDocumentIsReadAndCached() async throws {
        let fixture = Fixture()
        defer { fixture.tearDown() }
        let network = Network(files: try fixture.served(Self.offPR, signer: Curve25519.Signing.PrivateKey()))
        let store = try fixture.store(network)
        // Mis-signed: ignored, and nothing is cached.
        #expect(await store.flags() == nil)
        // Unsigned: ignored.
        await network.set(["flags.json": Data(Self.offPR.utf8)])
        #expect(await store.flags() == nil)
        // Signed: read, and cached for an offline launch.
        await network.set(try fixture.served(Self.offPR))
        #expect(await store.flags()?.off(cohort: "nightly") == ["pr-23456"])
        await network.set([:], offline: true)
        #expect(await store.flags()?.off(cohort: "nightly") == ["pr-23456"])
        // An edit on disk voids the cache.
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
        // Nothing is off before a verified document is read.
        #expect(!switches.isOff("pr-23456"))
        await reader.read()?.value
        #expect(switches.isOff("pr-23456"))
        #expect(!switches.isOff("pr-777"))
        // The Dev ring reads its own cohort.
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
        // The reader holds the updater weakly.
        defer { withExtendedLifetime(updater) {} }
        await reader.read()?.value
        #expect(switches.isOff("pr-23456"))
        // The next document is signed by someone else: ignored, and the verified cache still answers.
        await network.set(try fixture.served(#"{"version":1,"default":{"DisabledFeatures":["pr-1"]}}"#,
                                             signer: Curve25519.Signing.PrivateKey()))
        await reader.read()?.value
        #expect(switches.off == ["pr-23456"])
        // No verified document at all: nothing is off.
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
        // The dev read waits for the nightly one instead of fetching beside it.
        let joined = try #require(reader.read())
        await gate.release()
        await nightly.value
        // The nightly list is not the ring's any more: nothing of it applies.
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
        // A check publishes a new document while the first fetch is out: that fetch answers the old one.
        await network.set(try fixture.served(#"{"version":1,"default":{"DisabledFeatures":["pr-2"]}}"#))
        let asked = try #require(reader.read())
        await gate.release()
        await first.value
        await asked.value
        // The read asked after the check sees the new document.
        #expect(switches.off == ["pr-2"])
    }

    @Test func killSwitchReadsTheSharedSwitches() {
        #expect(!killSwitch("pr-999999001"))
        KillSwitches.shared.replace(off: ["pr-999999001"])
        defer { KillSwitches.shared.replace(off: []) }
        #expect(killSwitch("pr-999999001"))
    }
}

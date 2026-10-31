import CmuxNextCompat
import CmuxUpdater
@testable import CmuxNextUpdater
import CryptoKit
import Foundation
import Testing
@MainActor @Suite(.serialized) struct KillSwitchesTests {
    /// How long a test waits for a held fetch to arrive or a read to end before it fails. Far past
    /// what an in-memory fetch takes, even with the main actor busy, and far under the hang
    /// watchdog: a wait that can never end fails this test instead of cutting its shard short.
    nonisolated static let patience: Duration = .seconds(60)
    actor Gate {
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private var arrived = 0
        private var arrivals: [(id: Int, count: Int, waiter: CheckedContinuation<Bool, Never>)] = []
        private var nextArrival = 0
        func wait() async {
            arrived += 1
            let reached = arrivals.filter { $0.count <= arrived }
            arrivals.removeAll { $0.count <= arrived }
            reached.forEach { $0.waiter.resume(returning: true) }
            guard !isOpen else { return }
            await withCheckedContinuation { waiters.append($0) }
        }
        /// True once `count` fetches have reached the gate; false after `timeout` without them.
        func reached(_ count: Int, within timeout: Duration = KillSwitchesTests.patience) async -> Bool {
            guard arrived < count else { return true }
            nextArrival += 1
            let id = nextArrival
            let deadline = Task { try? await Task.sleep(for: timeout); self.expire(id) }
            defer { deadline.cancel() }
            return await withCheckedContinuation { arrivals.append((id, count, $0)) }
        }
        private func expire(_ id: Int) {
            guard let index = arrivals.firstIndex(where: { $0.id == id }) else { return }
            arrivals.remove(at: index).waiter.resume(returning: false)
        }
        func release() {
            isOpen = true
            waiters.forEach { $0.resume() }
            waiters = []
        }
    }
    /// Resumes a continuation once: the first of a read's end and its deadline.
    actor Once {
        private var done = false
        func resume(_ continuation: CheckedContinuation<Bool, Never>, _ value: Bool) {
            guard !done else { return }
            done = true
            continuation.resume(returning: value)
        }
    }
    /// True once `task` ends; false after `timeout`, leaving it running.
    static func finishes(_ task: Task<Void, Never>, within timeout: Duration = patience) async -> Bool {
        let once = Once()
        var deadline: Task<Void, Never>?
        let finished = await withCheckedContinuation { continuation in
            Task { await task.value; await once.resume(continuation, true) }
            deadline = Task { try? await Task.sleep(for: timeout); await once.resume(continuation, false) }
        }
        deadline?.cancel()
        return finished
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
        #expect(KillSwitchDocument(data: Data(#"{"version":true,"default":{"DisabledFeatures":["pr-1"]}}"#.utf8)) == nil)
        #expect(KillSwitchDocument(data: Data(#"{"version":1.5,"default":{"DisabledFeatures":["pr-1"]}}"#.utf8)) == nil)
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
    @Test func stoppingAnOldReaderPreventsItsInFlightReadFromOverwritingItsReplacement() async throws {
        let oldFixture = Fixture()
        let newFixture = Fixture()
        defer { oldFixture.tearDown(); newFixture.tearDown() }
        let oldGate = Gate()
        let oldNetwork = Network(files: try oldFixture.served(#"{"version":1,"default":{"DisabledFeatures":["pr-1"]}}"#))
        await oldNetwork.hold(oldGate)
        let newNetwork = Network(files: try newFixture.served(#"{"version":1,"default":{"DisabledFeatures":["pr-2"]}}"#))
        let switches = KillSwitches()
        let (oldUpdater, oldReader) = try Self.reader(store: try oldFixture.store(oldNetwork), switches: switches)
        let (newUpdater, newReader) = try Self.reader(store: try newFixture.store(newNetwork), switches: switches)
        defer { withExtendedLifetime((oldUpdater, newUpdater)) {} }
        let oldRead = try #require(oldReader.read())
        oldReader.stop()
        await newReader.read()?.value
        #expect(switches.off == ["pr-2"])
        await oldGate.release()
        await oldRead.value
        #expect(switches.off == ["pr-2"])
    }
    @Test func aRingThatReturnsBeforeTheFirstReadFinishesStillInvalidatesTheOldResult() async throws {
        let fixture = Fixture()
        defer { fixture.tearDown() }
        let network = Network(files: try fixture.served(#"{"version":1,"default":{"DisabledFeatures":["pr-1"]}}"#))
        let firstGate = Gate()
        await network.hold(firstGate)
        let switches = KillSwitches()
        let (updater, reader) = try Self.reader(store: try fixture.store(network), switches: switches)
        defer { withExtendedLifetime(updater) {} }
        let first = try #require(reader.read())
        updater.follow(ring: "dev")
        _ = try #require(reader.read())
        updater.follow(ring: "nightly")
        let latest = try #require(reader.read())
        // The first read's task runs only once this test suspends, so its fetches must be seen held
        // at `firstGate` before the network holds the next read at `queuedGate` instead. Without
        // this wait the first read's own fetches were held at `queuedGate`, which opens only after
        // the first read ends: the test waited forever.
        try #require(await firstGate.reached(2), "the first read never reached its fetches")
        let queuedGate = Gate()
        await network.hold(queuedGate)
        await network.set(try fixture.served(#"{"version":1,"default":{"DisabledFeatures":["pr-3"]}}"#))
        await firstGate.release()
        try #require(await Self.finishes(first), "the first read never ended")
        // Its ring is nightly again, but two later reads were asked: its list must not apply.
        #expect(switches.off.isEmpty)
        try #require(await queuedGate.reached(1), "the queued read never reached its fetch")
        await queuedGate.release()
        try #require(await Self.finishes(latest), "the queued read never ended")
        #expect(switches.off == ["pr-3"])
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
        try #require(await gate.reached(2), "the first read never reached its fetches")
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

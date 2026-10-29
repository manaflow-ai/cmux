import CmuxNextSettings
@testable import CmuxNextUpdater
import CmuxNextWakeups
import CryptoKit
import Foundation
import Testing

/// The signed `notes/flags.json` fetch: a 304 does nothing,
/// a tampered byte is rejected, a valid document reaches the receiver once, it
/// uses the release notes' own URL and content key, and the updater runs it at
/// start with Sparkle and automatic checks off.
@Suite struct FlagsDocumentFetchTests {
    static let feed = "https://notes.test/nightly-next/appcast.xml"

    /// A notes server holding files with ETags; answers `If-None-Match` with 304.
    actor Server: ConditionalFetching {
        var files: [String: (data: Data, etag: String)]
        private(set) var requested: [String] = []

        init(files: [String: (data: Data, etag: String)]) {
            self.files = files
        }

        func fetch(_ url: URL, ifNoneMatch etag: String?) async throws(ConditionalFetchError) -> ConditionalFetchResult {
            requested.append(url.path)
            guard let file = files[url.lastPathComponent] else { throw .http(status: 404) }
            if let etag, etag == file.etag { return .notModified }
            return .fetched(file.data, etag: file.etag)
        }
    }

    /// A server that is unreachable (offline).
    nonisolated struct Offline: ConditionalFetching {
        func fetch(_ url: URL, ifNoneMatch etag: String?) async throws(ConditionalFetchError) -> ConditionalFetchResult {
            throw .network(code: URLError.Code.notConnectedToInternet.rawValue)
        }
    }

    /// The feature store's stand-in: remembers every document and outcome handed to it.
    actor Receiver: FlagsDocumentReceiving {
        private(set) var received: [VerifiedFlagsDocument] = []
        private(set) var completed: [FlagsDocumentFetch.Outcome] = []
        private let initialETag: String?

        init(initialETag: String? = nil) {
            self.initialETag = initialETag
        }

        func lastETag() async -> String? { received.last?.etag ?? initialETag }
        func receive(_ document: VerifiedFlagsDocument) async { received.append(document) }
        func fetchCompleted(_ outcome: FlagsDocumentFetch.Outcome) async { completed.append(outcome) }
    }

    struct Fixture {
        let key = Curve25519.Signing.PrivateKey()
        let cache = FileManager.default.temporaryDirectory.appending(path: "cnc-flags-\(UUID().uuidString)", directoryHint: .isDirectory)
        let document = Data(#"{"version":1,"default":{"Features":{"example":"off"},"FeaturesSerial":7},"cohorts":{}}"#.utf8)

        var publicKey: String { key.publicKey.rawRepresentation.base64EncodedString() }

        func signature(of data: Data) throws -> Data {
            Data(try key.signature(for: data).base64EncodedString().utf8)
        }

        /// The published pair: `flags.json` (ETag `"v1"`) and its signature.
        func served(data: Data? = nil, signedData: Data? = nil) throws -> Server {
            let body = data ?? document
            return Server(files: ["flags.json": (body, "\"v1\""),
                                  "flags.json.sig": (try signature(of: signedData ?? body), "\"s1\"")])
        }

        func fetch(_ server: any ConditionalFetching) throws -> FlagsDocumentFetch {
            let store = try #require(ReleaseNotesStore(feedURL: FlagsDocumentFetchTests.feed, cache: cache, publicKey: publicKey))
            return store.flagsDocument(fetcher: server)
        }
    }

    static let enabled = FlagsFetchPolicy.enabled

    @Test func validDocumentIsReceivedOnceThenNotModified() async throws {
        let fixture = Fixture()
        let server = try fixture.served()
        let receiver = Receiver()
        let fetch = try fixture.fetch(server)

        #expect(await fetch.run(into: receiver, policy: Self.enabled) == .received)
        #expect(await fetch.run(into: receiver, policy: Self.enabled) == .notModified)

        let received = await receiver.received
        let signature = try String(decoding: fixture.signature(of: fixture.document), as: UTF8.self)
        #expect(received.count == 1)
        #expect(received.first?.data == fixture.document)
        #expect(received.first?.etag == "\"v1\"")
        #expect(received.first?.signature == signature)
        // The second launch asks for the document only: its 304 needs no signature.
        #expect(await server.requested.filter { $0.hasSuffix(".sig") }.count == 1)
    }

    /// A 304 hands nothing on but still reports a successful fetch (Chrome's
    /// variations_service.cc records a 304 as a successful fetch for safe mode).
    @Test func notModifiedDoesNothingButCountsAsASuccessfulFetch() async throws {
        let fixture = Fixture()
        let server = try fixture.served()
        let receiver = Receiver(initialETag: "\"v1\"")

        #expect(try await fixture.fetch(server).run(into: receiver, policy: Self.enabled) == .notModified)
        #expect(await receiver.received.isEmpty)
        #expect(await receiver.completed == [.notModified])
        #expect(FlagsDocumentFetch.Outcome.notModified.attempt == .succeeded)
        #expect(await server.requested == ["/nightly-next/notes/flags.json"])
    }

    @Test func tamperedByteIsRejected() async throws {
        let fixture = Fixture()
        var tampered = fixture.document
        tampered[tampered.startIndex + 30] ^= 0x01
        let server = try fixture.served(data: tampered, signedData: fixture.document)
        let receiver = Receiver()

        #expect(try await fixture.fetch(server).run(into: receiver, policy: Self.enabled) == .rejected(.badSignature))
        #expect(await receiver.received.isEmpty)
        #expect(await receiver.completed.map(\.attempt) == [.failed])
    }

    @Test func signatureByAnotherKeyIsRejected() async throws {
        let fixture = Fixture()
        let other = Fixture()
        let server = Server(files: ["flags.json": (fixture.document, "\"v1\""),
                                    "flags.json.sig": (try other.signature(of: fixture.document), "\"s1\"")])
        let receiver = Receiver()

        #expect(try await fixture.fetch(server).run(into: receiver, policy: Self.enabled) == .rejected(.badSignature))
        #expect(await receiver.received.isEmpty)
    }

    @Test func signatureNotFoundIsAFetchFailure() async throws {
        let fixture = Fixture()
        let server = Server(files: ["flags.json": (fixture.document, "\"v1\"")])
        let receiver = Receiver()

        let outcome = try await fixture.fetch(server).run(into: receiver, policy: Self.enabled)
        #expect(outcome == .rejected(.transport(.http(status: 404))))
        #expect(outcome.attempt == .failed)
        #expect(await receiver.received.isEmpty)
        #expect(await receiver.completed == [outcome])
    }

    /// Offline is a typed failure the receiver hears, so the fetch-failure streak counts it.
    @Test func offlineIsATypedFetchFailure() async throws {
        let receiver = Receiver()
        let outcome = try await Fixture().fetch(Offline()).run(into: receiver, policy: Self.enabled)
        #expect(outcome == .rejected(.transport(.network(code: URLError.Code.notConnectedToInternet.rawValue))))
        #expect(await receiver.completed.map(\.attempt) == [.failed])
    }

    @Test func unpublishedDocumentIsNotAFailure() async throws {
        let fixture = Fixture()
        let server = Server(files: [:])
        let receiver = Receiver()

        #expect(try await fixture.fetch(server).run(into: receiver, policy: Self.enabled) == .notPublished)
        #expect(await receiver.received.isEmpty)
        #expect(await receiver.completed.map(\.attempt) == [.succeeded])
    }

    /// The policy makes no request and tells the receiver, so a stored document does not apply either.
    @Test func managedPolicyTurnsTheFetchOffAndTellsTheReceiver() async throws {
        let fixture = Fixture()
        let server = try fixture.served()
        let receiver = Receiver()
        let policy = FlagsFetchPolicy(managedPolicy: [ManagedPreferences.disableRemoteFeatureFlagsKey: .bool(true)])

        #expect(try await fixture.fetch(server).run(into: receiver, policy: policy) == .disabledByPolicy)
        #expect(await server.requested.isEmpty)
        #expect(await receiver.received.isEmpty)
        #expect(await receiver.completed == [.disabledByPolicy])
    }

    /// `DisableRemoteFeatureFlags` is a published boolean policy key of the managed
    /// domain (`com.manaflow.cmux`), so the reader reads it; only a forced `true` counts.
    @Test func policyKeyIsReadFromTheManagedDomain() {
        let key = ManagedPreferences.policyKeys.first { $0.name == "DisableRemoteFeatureFlags" }
        #expect(key != nil)
        #expect(FlagsFetchPolicy.key == "DisableRemoteFeatureFlags")
        #expect(FlagsFetchPolicy(managedPolicy: ["DisableRemoteFeatureFlags": .bool(true)]).disablesRemoteFlags)
        #expect(!FlagsFetchPolicy(managedPolicy: ["DisableRemoteFeatureFlags": .string("true")]).disablesRemoteFlags)
        #expect(!FlagsFetchPolicy(managedPolicy: [:]).disablesRemoteFlags)
    }

    /// No second URL or key: the document sits in the release notes' folder and is
    /// checked with the store's content key (the compiled-in one by default).
    @Test func usesTheReleaseNotesFolderAndKey() throws {
        let cache = FileManager.default.temporaryDirectory
        let store = try #require(ReleaseNotesStore(feedURL: Self.feed, cache: cache))
        let fetch = store.flagsDocument()
        #expect(fetch.documentURL == store.notesBase.appending(path: "flags.json"))
        #expect(fetch.signatureURL == store.notesBase.appending(path: "flags.json.sig"))
        #expect(fetch.documentURL.absoluteString == "https://notes.test/nightly-next/notes/flags.json")
        #expect(store.publicKey == ContentSignature.publicKey)
    }

    // MARK: - The updater runs it at start

    /// A build with no Sparkle driver, automatic checks off and `DisableAutoUpdate` forced.
    @MainActor
    static func updater(feed: String, receiver: Receiver, fetcher: any ConditionalFetching) -> UpdaterService {
        let identity = UpdateBuildIdentity(bundleIdentifier: "com.cmuxterm.app.debug.flags-document", shortVersion: "1.0.0", build: "100",
                                           minimumSystemVersion: nil, infoFeedURL: feed, hasPublicKey: false)
        let defaults = UserDefaults(suiteName: "FlagsDocumentFetchTests.\(UUID().uuidString)")!
        defaults.set(false, forKey: "SUEnableAutomaticChecks")
        let updater = UpdaterService(identity: identity, policy: ManagedUpdatePolicy { true }, defaults: defaults,
                                     enableSparkle: false, recordsUpdates: false, work: BackgroundWork(label: "test.flags-document"),
                                     deadlines: MainDeadlineScheduler(work: MainWorkScheduler(budget: MainFrameBudget())),
                                     flagsReceiver: receiver, flagsFetcher: fetcher)
        updater.announcementsFetch = false
        return updater
    }

    @MainActor @Test func startFetchesWithSparkleAndAutomaticChecksOff() async throws {
        let server = try Fixture().served()
        let receiver = Receiver(initialETag: "\"v1\"")
        let updater = Self.updater(feed: "https://files-next.cmux.com/nightly-next/appcast-arm64.xml", receiver: receiver, fetcher: server)
        #expect(updater.controller == nil)

        updater.start()
        let task = try #require(updater.flagsFetchTask)
        #expect(await task.value == .notModified)
        #expect(await server.requested == ["/nightly-next/notes/flags.json"])
        #expect(await receiver.completed == [.notModified])
        #expect(updater.log.recent.contains { $0.contains("flags document: not modified") })
        // Once a launch: another call returns the same run, with no second request.
        #expect(await updater.fetchFlagsDocument()?.value == .notModified)
        #expect(await server.requested.count == 1)
    }

    @MainActor @Test func startHonorsTheManagedPolicy() async throws {
        let server = try Fixture().served()
        let receiver = Receiver()
        let updater = Self.updater(feed: "https://files-next.cmux.com/nightly-next/appcast-arm64.xml", receiver: receiver, fetcher: server)
        updater.remoteFeatureFlagsPolicy = FlagsFetchPolicy(disablesRemoteFlags: true)

        updater.start()
        let task = try #require(updater.flagsFetchTask)
        #expect(await task.value == .disabledByPolicy)
        #expect(await server.requested.isEmpty)
        #expect(await receiver.completed == [.disabledByPolicy])
    }

    @MainActor @Test func noHTTPSFeedFetchesNothing() async throws {
        let server = try Fixture().served()
        let receiver = Receiver()
        let updater = Self.updater(feed: "http://notes.test/appcast.xml", receiver: receiver, fetcher: server)

        updater.start()
        #expect(updater.flagsFetchTask == nil)
        #expect(updater.fetchFlagsDocument() == nil)
        #expect(await server.requested.isEmpty)
        #expect(updater.log.recent.contains { $0.contains("flags document: no https feed") })
    }
}

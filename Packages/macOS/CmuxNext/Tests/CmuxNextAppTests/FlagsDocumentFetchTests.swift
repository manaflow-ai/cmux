import CmuxNextUpdater
import CryptoKit
import Foundation
import Testing

/// The signed `notes/flags.json` fetch (p12-perf-process-093): a 304 does nothing,
/// a tampered byte is rejected, a valid document reaches the receiver once, and it
/// uses the release notes' own URL and content key.
@Suite struct FlagsDocumentFetchTests {
    static let feed = "https://notes.test/nightly-next/appcast.xml"

    /// A notes server holding files with ETags; answers `If-None-Match` with 304.
    actor Server: ConditionalFetching {
        var files: [String: (data: Data, etag: String)]
        private(set) var requested: [String] = []

        init(files: [String: (data: Data, etag: String)]) {
            self.files = files
        }

        func fetch(_ url: URL, ifNoneMatch etag: String?) async throws -> ConditionalFetchResult {
            requested.append(url.path)
            guard let file = files[url.lastPathComponent] else { throw ConditionalFetchError.http(status: 404) }
            if let etag, etag == file.etag { return .notModified }
            return .fetched(file.data, etag: file.etag)
        }
    }

    /// The feature store's stand-in: remembers every document handed to it.
    actor Receiver: FlagsDocumentReceiving {
        private(set) var received: [VerifiedFlagsDocument] = []
        private let initialETag: String?

        init(initialETag: String? = nil) {
            self.initialETag = initialETag
        }

        func lastETag() async -> String? { received.last?.etag ?? initialETag }
        func receive(_ document: VerifiedFlagsDocument) async { received.append(document) }
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

        func fetch(_ server: Server) throws -> FlagsDocumentFetch {
            let store = try #require(ReleaseNotesStore(feedURL: FlagsDocumentFetchTests.feed, cache: cache, publicKey: publicKey))
            return store.flagsDocument(fetcher: server)
        }
    }

    static let enabled = FlagsFetchPolicy { false }

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

    @Test func notModifiedDoesNothing() async throws {
        let fixture = Fixture()
        let server = try fixture.served()
        let receiver = Receiver(initialETag: "\"v1\"")

        #expect(try await fixture.fetch(server).run(into: receiver, policy: Self.enabled) == .notModified)
        #expect(await receiver.received.isEmpty)
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
        #expect(outcome == .rejected(.transport(String(describing: ConditionalFetchError.http(status: 404)))))
        #expect(await receiver.received.isEmpty)
    }

    @Test func unpublishedDocumentIsNotAFailure() async throws {
        let fixture = Fixture()
        let server = Server(files: [:])
        let receiver = Receiver()

        #expect(try await fixture.fetch(server).run(into: receiver, policy: Self.enabled) == .notPublished)
        #expect(await receiver.received.isEmpty)
    }

    @Test func managedPolicyTurnsTheFetchOff() async throws {
        let fixture = Fixture()
        let server = try fixture.served()
        let receiver = Receiver()

        #expect(try await fixture.fetch(server).run(into: receiver, policy: FlagsFetchPolicy { true }) == .disabledByPolicy)
        #expect(await server.requested.isEmpty)
        #expect(await receiver.received.isEmpty)
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
}

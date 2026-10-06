import CryptoKit
import Foundation
import Testing
@testable import CmuxNextUpdater

/// Notes come from the feed's folder, are trusted only when signed, and the
/// cache answers offline.
@Suite struct ReleaseNotesStoreTests {
    final class Server: AppcastFetching, @unchecked Sendable {
        var files: [String: Data] = [:]
        var offline = false
        private(set) var asked: [URL] = []
        func fetch(_ url: URL) async throws -> Data {
            asked.append(url)
            if offline { throw URLError(.notConnectedToInternet) }
            guard let data = files[url.absoluteString] else { throw URLError(.fileDoesNotExist) }
            return data
        }
    }

    private let key = Curve25519.Signing.PrivateKey()
    private var publicKey: String { key.publicKey.rawRepresentation.base64EncodedString() }
    private let notes = Data(#"{"version":1,"build":"7","shortVersion":"1.0.0-nightly.7","date":"2026-10-04","highlights":[],"changes":["a"]}"#.utf8)

    private func store(_ server: Server) throws -> ReleaseNotesStore {
        let cache = FileManager.default.temporaryDirectory.appending(path: "notes-\(UUID().uuidString)")
        return try #require(ReleaseNotesStore(feedURL: "https://files-next.cmux.com/nightly-next/appcast-arm64.xml",
                                              cache: cache, publicKey: publicKey, fetcher: server))
    }

    private func sign(_ data: Data) throws -> Data {
        Data((try key.signature(for: data).base64EncodedString() + "\n").utf8)
    }

    @Test func notesComeFromTheFeedFolderAndAreCachedWhenSigned() async throws {
        let server = Server()
        server.files["https://files-next.cmux.com/nightly-next/notes/7.json"] = notes
        server.files["https://files-next.cmux.com/nightly-next/notes/7.json.sig"] = try sign(notes)
        let store = try store(server)
        #expect(await store.notes(for: "7")?.changes == ["a"])
        server.offline = true
        #expect(await store.notes(for: "7")?.changes == ["a"], "the cache answers offline")
    }

    @Test func unsignedOrTamperedNotesAreRefused() async throws {
        let server = Server()
        var tampered = notes
        tampered.append(UInt8(ascii: " "))
        server.files["https://files-next.cmux.com/nightly-next/notes/7.json"] = tampered
        server.files["https://files-next.cmux.com/nightly-next/notes/7.json.sig"] = try sign(notes)
        let store = try store(server)
        #expect(await store.notes(for: "7") == nil)
        server.offline = true
        #expect(await store.notes(for: "7") == nil, "nothing unverified was cached")
    }

    @Test func notesNamingAnotherBuildAreRefused() async throws {
        let server = Server()
        server.files["https://files-next.cmux.com/nightly-next/notes/8.json"] = notes
        server.files["https://files-next.cmux.com/nightly-next/notes/8.json.sig"] = try sign(notes)
        #expect(await (try store(server)).notes(for: "8") == nil)
    }

    @Test func theIndexIsVerifiedToo() async throws {
        let server = Server()
        let index = Data(#"{"version":1,"builds":[{"build":"7","shortVersion":"1.0.0-nightly.7","date":"2026-10-04","highlights":0}]}"#.utf8)
        server.files["https://files-next.cmux.com/nightly-next/notes/index.json"] = index
        server.files["https://files-next.cmux.com/nightly-next/notes/index.json.sig"] = try sign(index)
        #expect(await (try store(server)).index().map(\.build) == ["7"])
    }
}

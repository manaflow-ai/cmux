@testable import CmuxNextApp
import CmuxNextPages
import CmuxNextSettings
import CmuxNextUpdater
import CryptoKit
import Foundation
import Testing

/// What's New paints its first screen inside the 500 ms paint hold only when
/// `cmux.changelog.get` answers fast: a build's verified notes come from the
/// local cache once fetched, and a fetch asks for the notes and their
/// signature together (perceived speed, What's New first frame).
@MainActor @Suite(.serialized) struct ChangelogNotesLoadTests {
    static let context = PageCallContext(page: "cmux.changelog")
    static let build = "4242"

    /// A notes server: answers the files it holds, counts every request, and
    /// can hold each request until two have been in flight at once (or a second passes).
    actor Network: AppcastFetching {
        var files: [String: Data]
        let pairRequests: Bool
        private(set) var requested: [String] = []
        private(set) var inFlight = 0
        private(set) var peakInFlight = 0

        init(files: [String: Data], pairRequests: Bool = false) {
            self.files = files
            self.pairRequests = pairRequests
        }

        func fetch(_ url: URL) async throws -> Data {
            requested.append(url.lastPathComponent)
            inFlight += 1
            peakInFlight = max(peakInFlight, inFlight)
            defer { inFlight -= 1 }
            if pairRequests {
                for _ in 0..<100 where peakInFlight < 2 { try await Task.sleep(for: .milliseconds(10)) }
            }
            guard let data = files[url.lastPathComponent] else { throw URLError(.fileDoesNotExist) }
            return data
        }

        func requests(for name: String) -> Int { requested.filter { $0.hasPrefix(name) }.count }
    }

    struct Fixture {
        let key = Curve25519.Signing.PrivateKey()
        let cache = FileManager.default.temporaryDirectory.appending(path: "cnc-changelog-notes-\(UUID().uuidString)", directoryHint: .isDirectory)

        var publicKey: String { key.publicKey.rawRepresentation.base64EncodedString() }

        func notes(_ title: String) throws -> Data {
            try JSONEncoder().encode(ReleaseNotes(version: 1, build: ChangelogNotesLoadTests.build, shortVersion: "0.1.4242",
                                                  date: "2026-10-15", highlights: [], changes: [title]))
        }

        /// The served pair: notes and their Ed25519 signature.
        func served(_ title: String) throws -> [String: Data] {
            let data = try notes(title)
            let signature = try key.signature(for: data).base64EncodedString()
            return ["\(ChangelogNotesLoadTests.build).json": data, "\(ChangelogNotesLoadTests.build).json.sig": Data(signature.utf8)]
        }

        func page(_ network: Network) throws -> ChangelogPageProvider {
            let store = try #require(ReleaseNotesStore(feedURL: "https://notes.test/nightly-next/appcast.xml", cache: cache,
                                                       publicKey: publicKey, fetcher: network))
            return ChangelogPageProvider(source: store, currentBuild: ChangelogNotesLoadTests.build)
        }

        func get(_ page: ChangelogPageProvider) async throws -> [String] {
            let result = try await page.call("cmux.changelog.get", params: ["build": .string(ChangelogNotesLoadTests.build)],
                                             context: ChangelogNotesLoadTests.context)
            return result["changes"]?.arrayValue?.compactMap(\.stringValue) ?? []
        }

        func tearDown() { try? FileManager.default.removeItem(at: cache) }
    }

    @Test func notesFetchedOnceOpenFromTheCacheWithoutTheNetwork() async throws {
        let fixture = Fixture()
        defer { fixture.tearDown() }
        let first = Network(files: try fixture.served("Faster What's New"))
        #expect(try await fixture.get(try fixture.page(first)) == ["Faster What's New"])

        // A later open (a new store, as after relaunch) reads the verified cache: no request for the build.
        let later = Network(files: try fixture.served("Faster What's New"))
        #expect(try await fixture.get(try fixture.page(later)) == ["Faster What's New"])
        #expect(await later.requests(for: "\(Self.build).json") == 0)
    }

    @Test func cachedNotesThatNoLongerVerifyAreFetchedAgain() async throws {
        let fixture = Fixture()
        defer { fixture.tearDown() }
        _ = try await fixture.get(try fixture.page(Network(files: try fixture.served("Signed"))))
        // Tampered cache: the signature no longer matches, so the page shows the network's verified notes.
        try fixture.notes("Tampered").write(to: fixture.cache.appending(path: "\(Self.build).json"))
        let network = Network(files: try fixture.served("Signed"))
        #expect(try await fixture.get(try fixture.page(network)) == ["Signed"])
        #expect(await network.requests(for: "\(Self.build).json") == 2)

        // An unsigned answer is never shown, cached or not.
        try fixture.notes("Tampered").write(to: fixture.cache.appending(path: "\(Self.build).json"))
        var unsigned = try fixture.served("Unsigned")
        unsigned["\(Self.build).json"] = try fixture.notes("Forged")
        let forged = try fixture.page(Network(files: unsigned))
        await #expect(throws: PageError.self) { _ = try await fixture.get(forged) }
    }

    @Test func notesAndSignatureAreRequestedTogether() async throws {
        let fixture = Fixture()
        defer { fixture.tearDown() }
        let network = Network(files: try fixture.served("Parallel"), pairRequests: true)
        #expect(try await fixture.get(try fixture.page(network)) == ["Parallel"])
        #expect(await network.peakInFlight == 2)
    }
}

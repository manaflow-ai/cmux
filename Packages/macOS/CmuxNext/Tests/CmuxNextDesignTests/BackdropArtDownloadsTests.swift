import CryptoKit
@testable import CmuxNextDesign
import Foundation
import Testing

/// Art that is not bundled downloads once into the backgrounds folder, and only bytes matching
/// the manifest's SHA-256 are kept (cx-t2x.7).
@Suite struct BackdropArtDownloadsTests {
    private static func folder() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("backdrop-art-\(UUID().uuidString)", isDirectory: true)
    }

    private actor Fetches {
        var urls: [URL] = []
        func record(_ url: URL) { urls.append(url) }
    }

    @Test func aDownloadIsKeptOnlyWhenItsHashMatches() async throws {
        let body = Data("not really an image".utf8)
        let sha = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
        let fetches = Fetches()
        let folder = Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let downloads = BackdropArtDownloads(folder: folder) { url in
            await fetches.record(url)
            return body
        }

        let file = try #require(await downloads.file(id: "some-work", sha256: sha))
        #expect(try Data(contentsOf: file) == body)
        #expect(downloads.cachedFile(id: "some-work") == file)
        _ = await downloads.file(id: "some-work", sha256: sha)
        #expect(await fetches.urls.map(\.lastPathComponent) == ["\(sha).avif"])

        let wrong = String(repeating: "0", count: 64)
        #expect(await downloads.file(id: "tampered", sha256: wrong) == nil)
        #expect(downloads.cachedFile(id: "tampered") == nil)
    }
}

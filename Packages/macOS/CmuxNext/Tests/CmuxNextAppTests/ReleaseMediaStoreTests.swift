@testable import CmuxNextUpdater
import Foundation
import Testing

struct ReleaseMediaStoreTests {
    @Test func inlinesAnIsoBmffVideoAsVideoData() {
        let bytes = Data([0, 0, 0, 24, 0x66, 0x74, 0x79, 0x70, 0x69, 0x73, 0x6F, 0x6D, 0, 0, 0, 0,
                          0x69, 0x73, 0x6F, 0x6D, 0x6D, 0x70, 0x34, 0x32])
        #expect(ReleaseMediaStore.kind(of: bytes) == .video)
        #expect(ReleaseMediaStore.admits(bytes))
        #expect(ReleaseMediaStore.dataURL(bytes)?.absoluteString.hasPrefix("data:video/mp4;base64,") == true)
    }

    @Test func acceptsOnlyThePublicCmuxMediaBranch() {
        #expect(ReleaseMediaStore.isPublicHighlightURL(URL(string: "https://raw.githubusercontent.com/manaflow-ai/cmux/pr-media/25135/after.png")!))
        #expect(!ReleaseMediaStore.isPublicHighlightURL(URL(string: "https://raw.githubusercontent.com/someone/cmux/pr-media/25135/after.png")!))
        #expect(!ReleaseMediaStore.isPublicHighlightURL(URL(string: "https://raw.githubusercontent.com/manaflow-ai/cmux/pr-media/25135/after.png?redirect=elsewhere")!))
        #expect(!ReleaseMediaStore.isPublicHighlightURL(URL(string: "https://raw.githubusercontent.com.evil.example/manaflow-ai/cmux/pr-media/after.png")!))
        #expect(!ReleaseMediaStore.isPublicHighlightURL(URL(string: "https://raw.githubusercontent.com/manaflow-ai/cmux/pr-media/../main/file.png")!))
        #expect(!ReleaseMediaStore.isPublicHighlightURL(URL(string: "https://raw.githubusercontent.com/manaflow-ai/cmux/pr-media/%2e%2e/main/file.png")!))
    }

    @Test(arguments: ["../main/file.png", "./file.png", "%2e%2e/main/file.png",
                      "%252e%252e/main/file.png", "%25252e%25252e/main/file.png",
                      "%5c..%5cmain/file.png", "\\..\\main/file.png",
                      "%255c..%255cmain/file.png", "%2e%2e%2fmain/file.png"])
    func rejectsPathsThatChangeAfterNormalization(_ path: String) throws {
        let url = try #require(URL(string: "https://raw.githubusercontent.com/manaflow-ai/cmux/pr-media/" + path))
        #expect(!ReleaseMediaStore.isPublicHighlightURL(url))
    }

    @Test func acceptsAnOrdinaryPercentEncodedFilename() throws {
        let url = try #require(URL(string: "https://raw.githubusercontent.com/manaflow-ai/cmux/pr-media/123/screen%20shot.png"))
        #expect(ReleaseMediaStore.isPublicHighlightURL(url))
    }

    @Test func aMediaRoleRoundTripsAndALonePictureHasNone() throws {
        let json = Data("""
        [{"url": "https://raw.githubusercontent.com/manaflow-ai/cmux/pr-media/1/after.png", "sha256": "a", "kind": "image", "alt": "After", "role": "after"},
         {"url": "https://raw.githubusercontent.com/manaflow-ai/cmux/pr-media/1/shot.png", "sha256": "b", "kind": "image", "alt": "Shot"}]
        """.utf8)
        let media = try JSONDecoder().decode([ReleaseNotes.Media].self, from: json)
        #expect(media.map(\.role) == ["after", nil])
        let again = try JSONDecoder().decode([ReleaseNotes.Media].self, from: JSONEncoder().encode(media))
        #expect(again == media)
        let lone = try #require(String(bytes: JSONEncoder().encode(media[1]), encoding: .utf8))
        #expect(!lone.contains("role"))
    }

    @Test func inliningKeepsEachPictureRole() async throws {
        let cache = FileManager.default.temporaryDirectory.appending(path: "release-media-role-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: cache) }
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        var pictures: [ReleaseNotes.Media] = []
        for (index, role) in ["after", "before"].enumerated() {
            let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, UInt8(index)])
            let hash = ReleaseMediaStore.sha256(png)
            try png.write(to: cache.appending(path: "sha256-\(hash)"))
            let url = try #require(URL(string: "https://raw.githubusercontent.com/manaflow-ai/cmux/pr-media/1/\(role).png"))
            pictures.append(ReleaseNotes.Media(url: url, sha256: hash, kind: "image", alt: role, role: role))
        }
        let notes = ReleaseNotes(version: 1, build: "1", shortVersion: "1.0.0", date: "2026-11-08",
                                 highlights: [.init(id: "pair", title: "Pair", body: "", media: pictures, action: nil)], changes: [])
        let store = ReleaseMediaStore(cache: cache, bundledDirectories: [], fetcher: NoNetwork(), siteBase: nil, reelBase: nil)
        let inlined = await store.inlined(notes).highlights[0].media
        #expect(inlined.map(\.role) == ["after", "before"])
        #expect(inlined.allSatisfy { $0.url.scheme == "data" })
    }
}

private struct NoNetwork: AppcastFetching {
    func fetch(_ url: URL) async throws -> Data { throw URLError(.notConnectedToInternet) }
}

@Suite(.serialized) struct ReleaseMediaRedirectTests {
    @Test(arguments: [301, 302, 303, 307, 308])
    func doesNotRequestARedirectDestination(_ status: Int) async throws {
        MediaRedirectProtocol.reset(status: status)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 5
        configuration.protocolClasses = [MediaRedirectProtocol.self]
        let fetcher = URLSessionAppcastFetcher(configuration: configuration, followsRedirects: false)
        let url = try #require(URL(string: "https://raw.githubusercontent.com/manaflow-ai/cmux/pr-media/image.png"))
        await #expect(throws: AppcastParseError(message: "feed returned HTTP \(status)")) {
            _ = try await fetcher.fetch(url)
        }
        #expect(MediaRedirectProtocol.paths == ["/manaflow-ai/cmux/pr-media/image.png"])
    }

    @Test func ordinaryFeedFetcherCanStillFollowRedirects() async throws {
        MediaRedirectProtocol.reset(status: 302)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 5
        configuration.protocolClasses = [MediaRedirectProtocol.self]
        let fetcher = URLSessionAppcastFetcher(configuration: configuration, followsRedirects: true)
        let url = try #require(URL(string: "https://raw.githubusercontent.com/manaflow-ai/cmux/pr-media/image.png"))
        let bytes = try await fetcher.fetch(url)
        #expect(bytes == Data("destination".utf8))
        #expect(MediaRedirectProtocol.paths == ["/manaflow-ai/cmux/pr-media/image.png", "/manaflow-ai/cmux/main/file.png"])
    }
}

/// Sends actual URLSession redirect callbacks, including an otherwise successful destination.
private nonisolated final class MediaRedirectProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var recorded: [String] = []
    private nonisolated(unsafe) static var status = 302
    static var paths: [String] { lock.withLock { recorded } }
    static func reset(status: Int) { lock.withLock { self.status = status; recorded = [] } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        guard let url = request.url else { return }
        let status = Self.lock.withLock { Self.recorded.append(url.path); return Self.status }
        if url.path == "/manaflow-ai/cmux/pr-media/image.png" {
            let target = URL(string: "https://raw.githubusercontent.com/manaflow-ai/cmux/main/file.png")!
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                           headerFields: ["Location": target.absoluteString, "Content-Length": "0"])!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
            // Refusing a redirect continues the original response. Complete its empty body
            // instead of leaving the data task waiting for this protocol until its deadline.
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        } else {
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("destination".utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }
}

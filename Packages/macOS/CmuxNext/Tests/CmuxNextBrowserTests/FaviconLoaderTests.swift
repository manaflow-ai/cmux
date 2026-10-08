import AppKit
@testable import CmuxNextBrowser
import Foundation
import Synchronization
import Testing

/// Serves favicon requests for `FaviconLoaderTests` and records them.
nonisolated final class FaviconStubProtocol: URLProtocol, @unchecked Sendable {
    struct Served {
        var headers: [[String: String]] = []
        var body = Data()
    }

    static let served = Mutex(Served())

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = Self.served.withLock { served -> Data in
            served.headers.append(request.allHTTPHeaderFields ?? [:])
            return served.body
        }
        let fields = ["Content-Type": "image/png"]
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: fields)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// A page chooses its favicon URL, and the app process fetches it: the
/// fetch must not read local files or buffer an unbounded response.
@MainActor @Suite(.serialized)
struct FaviconLoaderTests {
    static func png() -> Data {
        let image = NSImage(size: NSSize(width: 4, height: 4))
        image.lockFocus()
        NSColor.gray.setFill()
        NSRect(x: 0, y: 0, width: 4, height: 4).fill()
        image.unlockFocus()
        let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
        return rep.representation(using: .png, properties: [:])!
    }

    static func loader() -> BrowserFaviconLoader {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FaviconStubProtocol.self]
        return BrowserFaviconLoader(session: URLSession(configuration: configuration))
    }

    static func serve(_ body: Data) {
        FaviconStubProtocol.served.withLock { $0 = .init(body: body) }
    }

    @Test func aSmallIconLoads() async {
        Self.serve(Self.png())
        #expect(await Self.loader().favicon(at: URL(string: "https://a.example/favicon.png")!, profile: .default) != nil)
    }

    @Test func anOversizedResponseIsRefused() async {
        Self.serve(Self.png() + Data(count: 3 << 20))
        #expect(await Self.loader().favicon(at: URL(string: "https://a.example/huge.png")!, profile: .default) == nil)
    }

    @Test func aLocalFileIsNeverRead() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("favicon-\(UUID().uuidString).png")
        try Self.png().write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(await Self.loader().favicon(at: file, profile: .default) == nil)
    }

    /// Each profile has its own cache: an icon one profile loaded is not
    /// handed to another without that profile's own fetch.
    @Test func profilesDoNotShareCachedIcons() async {
        Self.serve(Self.png())
        let loader = Self.loader()
        let url = URL(string: "https://b.example/favicon.png")!
        let other = BrowserProfileID(rawValue: UUID())
        #expect(await loader.favicon(at: url, profile: .default) != nil)
        #expect(loader.cachedFavicon(at: url, profile: .default) != nil)
        #expect(loader.cachedFavicon(at: url, profile: other) == nil)
        let before = FaviconStubProtocol.served.withLock { $0.headers.count }
        #expect(await loader.favicon(at: url, profile: other) != nil)
        #expect(FaviconStubProtocol.served.withLock { $0.headers.count } == before + 1, "fetched again for the other profile")
        loader.forget(profile: other)
        #expect(loader.cachedFavicon(at: url, profile: other) == nil)
    }

    @Test func requestsCarryNoCookies() async {
        Self.serve(Self.png())
        _ = await Self.loader().favicon(at: URL(string: "https://c.example/favicon.png")!, profile: .default)
        let headers = FaviconStubProtocol.served.withLock { $0.headers.last ?? [:] }
        #expect(headers["Cookie"] == nil)
    }

    @Test func largeIconsAreRedrawnSmall() throws {
        let big = NSImage(size: NSSize(width: 512, height: 512))
        big.lockFocus()
        NSColor.gray.setFill()
        NSRect(x: 0, y: 0, width: 512, height: 512).fill()
        big.unlockFocus()
        let data = NSBitmapImageRep(data: big.tiffRepresentation!)!.representation(using: .png, properties: [:])!
        let image = try #require(BrowserFaviconLoader.decode(data))
        let cg = try #require(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        #expect(max(cg.width, cg.height) <= BrowserFaviconLoader.maximumPixels)
        #expect(image.size.width == 16)
    }
}

@Suite struct LRUCacheTests {
    @Test func dropsTheLeastRecentlyUsedEntry() {
        var cache = LRUCache<String, Int>(capacity: 2)
        cache.set(1, for: "a")
        cache.set(2, for: "b")
        _ = cache.value(for: "a")
        cache.set(3, for: "c")
        #expect(cache.peek("a") == 1)
        #expect(cache.peek("b") == nil)
        #expect(cache.peek("c") == 3)
        #expect(cache.count == 2)
    }

    @Test func replacingAValueKeepsOneEntry() {
        var cache = LRUCache<String, Int>(capacity: 2)
        cache.set(1, for: "a")
        cache.set(2, for: "a")
        #expect(cache.count == 1)
        #expect(cache.value(for: "a") == 2)
    }
}

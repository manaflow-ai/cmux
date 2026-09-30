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
        #expect(await Self.loader().favicon(at: URL(string: "https://a.example/favicon.png")!) != nil)
    }

    @Test func anOversizedResponseIsRefused() async {
        Self.serve(Self.png() + Data(count: 3 << 20))
        #expect(await Self.loader().favicon(at: URL(string: "https://a.example/huge.png")!) == nil)
    }

    @Test func aLocalFileIsNeverRead() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("favicon-\(UUID().uuidString).png")
        try Self.png().write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(await Self.loader().favicon(at: file) == nil)
    }
}

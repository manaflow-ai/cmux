@testable import CmuxNextDesign
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

/// Bringing your own background in (backgrounds plan phase 3): a file is checked to decode or play
/// before it is copied, a link downloads over https only, is named for its bytes and capped in
/// size, and your images can be removed and counted.
@Suite(.serialized) struct BackdropImportTests {
    static func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A 4×4 PNG's bytes.
    static func png() throws -> Data {
        let data = NSMutableData()
        let context = try #require(CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    @Test func aFileThatDoesNotDecodeIsNeverCopiedIn() async throws {
        let source = try Self.folder(), backgrounds = try Self.folder()
        let images = BackdropUserImages(folder: backgrounds)
        let good = source.appendingPathComponent("Sea.png"), bad = source.appendingPathComponent("Notes.png")
        try Self.png().write(to: good)
        try Data("not a picture".utf8).write(to: bad)
        #expect(await BackdropUserImages.isUsable(good))
        #expect(!(await BackdropUserImages.isUsable(bad)))
        await #expect(throws: BackdropUserImages.ImportError.notMedia) { try await images.adoptChecked(bad) }
        #expect(images.list().isEmpty, "a broken picture was listed")
        let selection = try await images.adoptChecked(good)
        #expect(images.list() == [selection])
        #expect(images.usage() == Int64(try Self.png().count))
        try images.remove(selection)
        #expect(images.list().isEmpty && images.usage() == 0)
        // Only the folder's own images can be removed.
        #expect(throws: (any Error).self) { try images.remove(.file(path: good.path)) }
        #expect(FileManager.default.fileExists(atPath: good.path))
    }

    @Test func aLinkMustBeHTTPS() async {
        for text in ["http://example.com/sea.jpg", "file:///etc/hosts", "ftp://example.com/a.png"] {
            await #expect(throws: BackdropUserImages.ImportError.notHTTPS) { _ = try await BackdropUserImages.download(URL(string: text)!) }
        }
    }

    @Test func aLinkIsNamedForItsBytesAndRefusedWhenItIsNotMedia() async throws {
        let session = StubResponses.session()
        StubResponses.set(["https://example.com/photo?id=7": (try Self.png(), "application/octet-stream", 200),
                           "https://example.com/page.png": (Data("<html></html>".utf8), "text/html", 200),
                           "https://example.com/gone.png": (Data(), "text/plain", 404)])
        let file = try await BackdropUserImages.download(URL(string: "https://example.com/photo?id=7")!, session: session)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        // PNG bytes behind a link with no extension: named for what they are.
        #expect(file.lastPathComponent == "photo.png")
        await #expect(throws: BackdropUserImages.ImportError.notMedia) {
            _ = try await BackdropUserImages.download(URL(string: "https://example.com/page.png")!, session: session)
        }
        await #expect(throws: BackdropUserImages.ImportError.downloadFailed) {
            _ = try await BackdropUserImages.download(URL(string: "https://example.com/gone.png")!, session: session)
        }
    }
}

/// Canned answers by URL for a URLSession, so link downloads run without a network.
nonisolated final class StubResponses: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var answers: [String: (Data, String, Int)] = [:]
    static let lock = NSLock()

    static func set(_ answers: [String: (Data, String, Int)]) { lock.withLock { self.answers = answers } }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubResponses.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let answer = Self.lock.withLock({ Self.answers[url.absoluteString] }),
              let response = HTTPURLResponse(url: url, statusCode: answer.2, httpVersion: "HTTP/1.1",
                                             headerFields: ["Content-Type": answer.1, "Content-Length": "\(answer.0.count)"]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: answer.0)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

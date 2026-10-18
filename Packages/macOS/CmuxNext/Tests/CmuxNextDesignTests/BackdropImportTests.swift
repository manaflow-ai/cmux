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
        let configuration = StubResponses.configuration()
        StubResponses.set(["https://example.com/photo?id=7": .init(body: try Self.png(), type: "application/octet-stream"),
                           "https://example.com/page.png": .init(body: Data("<html></html>".utf8), type: "text/html"),
                           "https://example.com/gone.png": .init(body: Data(), type: "text/plain", status: 404)])
        let file = try await BackdropUserImages.download(URL(string: "https://example.com/photo?id=7")!, configuration: configuration)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        // PNG bytes behind a link with no extension: named for what they are.
        #expect(file.lastPathComponent == "photo.png")
        await #expect(throws: BackdropUserImages.ImportError.notMedia) {
            _ = try await BackdropUserImages.download(URL(string: "https://example.com/page.png")!, configuration: configuration)
        }
        await #expect(throws: BackdropUserImages.ImportError.downloadFailed) {
            _ = try await BackdropUserImages.download(URL(string: "https://example.com/gone.png")!, configuration: configuration)
        }
    }

    /// The review's path traversal (#21731): an encoded `../` in the link's name never leaves the
    /// download's own folder.
    @Test func aLinkNameCannotClimbOutOfTheDownloadFolder() async throws {
        let configuration = StubResponses.configuration()
        let link = "https://example.com/..%2F..%2Fevil.png"
        StubResponses.set([link: .init(body: try Self.png(), type: "image/png")])
        let file = try await BackdropUserImages.download(URL(string: link)!, configuration: configuration)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        #expect(file.lastPathComponent == "evil.png")
        #expect(file.deletingLastPathComponent().lastPathComponent.hasPrefix("cmux-background-"))
        #expect(BackdropUserImages.safeStem(URL(string: "https://example.com/...png")!) == "Background")
        #expect(BackdropUserImages.safeStem(URL(string: "https://example.com/a%3Ab%5Cc.png")!) == "a-b-c")
    }

    @Test func aLinkStopsAtItsCapAndNeverFollowsARedirectOffHTTPS() async throws {
        let configuration = StubResponses.configuration()
        let big = Data(count: Int(BackdropUserImages.maximumImageBytes) + 1)
        StubResponses.set([
            // Refused from its declared length, before the body.
            "https://example.com/declared.png": .init(body: Data(), type: "image/png",
                                                     headers: ["Content-Length": "\(BackdropUserImages.maximumImageBytes + 1)"]),
            // No length declared: stopped once the count passes the cap for a picture.
            "https://example.com/streamed.png": .init(body: big, type: "image/png", headers: ["Content-Length": ""]),
            "https://example.com/hop.png": .init(body: Data(), type: "text/plain", status: 302,
                                                 headers: ["Location": "http://example.com/plain.png"]),
        ])
        for link in ["https://example.com/declared.png", "https://example.com/streamed.png"] {
            await #expect(throws: BackdropUserImages.ImportError.tooLarge) {
                _ = try await BackdropUserImages.download(URL(string: link)!, configuration: configuration)
            }
        }
        await #expect(throws: BackdropUserImages.ImportError.notHTTPS) {
            _ = try await BackdropUserImages.download(URL(string: "https://example.com/hop.png")!, configuration: configuration)
        }
    }
}

/// Canned answers by URL for a URLSession, so link downloads run without a network.
nonisolated final class StubResponses: URLProtocol, @unchecked Sendable {
    struct Answer {
        var body: Data
        var type: String
        var status = 200
        var headers: [String: String] = [:]
    }

    nonisolated(unsafe) static var answers: [String: Answer] = [:]
    static let lock = NSLock()

    static func set(_ answers: [String: Answer]) { lock.withLock { self.answers = answers } }

    static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubResponses.self]
        return configuration
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let answer = Self.lock.withLock({ Self.answers[url.absoluteString] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        var fields = ["Content-Type": answer.type, "Content-Length": "\(answer.body.count)"].merging(answer.headers) { $1 }
        fields = fields.filter { !$0.value.isEmpty }
        let response = HTTPURLResponse(url: url, statusCode: answer.status, httpVersion: "HTTP/1.1", headerFields: fields)!
        if (300..<400).contains(answer.status), let location = fields["Location"].flatMap(URL.init(string:)) {
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: location), redirectResponse: response)
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        var offset = 0
        while offset < answer.body.count {
            let end = min(offset + 1 << 20, answer.body.count)
            client?.urlProtocol(self, didLoad: answer.body.subdata(in: offset..<end))
            offset = end
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

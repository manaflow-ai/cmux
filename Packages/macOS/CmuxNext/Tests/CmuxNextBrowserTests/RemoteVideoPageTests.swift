import AppKit
import AVFoundation
@testable import CmuxNextBrowser
import Foundation
import Network
import Testing
import CmuxNextTestSupport

/// ask-76f83a7020 (Leo: "id like to be able to watch .mp4s direclty in cmux next"): a web .mp4
/// whose server sends it as a generic file, as raw.githubusercontent.com sends the nightly reel
/// (`application/octet-stream`, `nosniff`), plays in the WebKit tab at its own address instead of
/// downloading. Runs a real WebKit page against a local server that answers range requests.
@MainActor @Suite(.closesItsWindows, .serialized, .timeLimit(.minutes(2))) struct RemoteVideoPageTests {
    @Test func aVideoSentAsAGenericFilePlaysInTheTab() async throws {
        let server = try await VideoServer.start(video: try await Self.makeVideo())
        defer { server.stop() }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFrontRegardless()
        defer {
            window.orderOut(nil)
            window.close()
        }
        let intents = Intents()
        let downloads = FileManager.default.temporaryDirectory
            .appendingPathComponent("cn-remote-video-dl-\(UUID().uuidString.prefix(8).lowercased())", isDirectory: true)
        defer { Task.detached { try? FileManager.default.removeItem(at: downloads) } }
        let engine = WebKitEngine(fileInput: NoFileInput(), stores: .inMemory(), downloadsDirectory: downloads)  // the tab holds its engine weakly
        let page = engine.makeWebKitTab()
        defer { page.close() }
        page.delegate = intents
        window.contentView = page.contentView
        func title() async -> BrowserJSValue? { try? await page.evaluate("document.readyState === 'complete' && document.title", world: .page, gesture: .agent) }

        // Two pages, then the second's link to the video.
        page.load(server.url("/a"))
        try await Self.until("a loads") { await title() == .string("a") }
        _ = try await page.evaluate("document.querySelector('a').click(); true", world: .page, gesture: .agent)
        try await Self.until("b loads") { await title() == .string("b") }
        _ = try await page.evaluate("document.querySelector('a').click(); true", world: .page, gesture: .agent)

        try await Self.until("the video plays") {
            let time = try? await page.evaluate("document.querySelector('video')?.currentTime ?? 0", world: .page, gesture: .agent)
            if case .number(let seconds)? = time { return seconds > 0 }
            return false
        }
        let reel = server.url("/reel.mp4")
        #expect(page.state.url == reel, "the tab shows \(page.state.url?.absoluteString ?? "nothing")")
        #expect(!intents.downloaded, "the video downloaded")

        // The player has its own place in the back list: Back shows b, Forward the video again.
        func list() -> [String] {
            let history = page.webView.backForwardList
            return (history.backList + [history.currentItem].compactMap(\.self) + history.forwardList).map(\.url.lastPathComponent)
        }
        #expect(list() == ["a", "b", "reel.mp4"])
        page.goBack()
        try await Self.until("Back shows b") { await title() == .string("b") }
        page.goForward()
        try await Self.until("Forward shows the video") { await title() == .string("reel.mp4") }
        #expect(list() == ["a", "b", "reel.mp4"])
        #expect(!intents.downloaded, "the video downloaded")

        // A video a form posts for cannot be fetched again, so it still downloads.
        page.load(server.url("/c"))
        try await Self.until("c loads") { await title() == .string("c") }
        _ = try await page.evaluate("document.forms[0].submit(); true", world: .page, gesture: .agent)
        try await Self.until("the posted video downloads") { intents.downloaded }
    }

    /// A local .mp4 opened in a WebKit tab (the CEF tab hands it off here) plays, and does not end
    /// in WebKit's "Plug-in handled load" error page. Fails on a tab that cancels the navigation.
    @Test func aLocalVideoPlaysInTheWebKitTab() async throws {
        let video = FileManager.default.temporaryDirectory
            .appendingPathComponent("cn-local-video-\(UUID().uuidString.prefix(8).lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: video, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: video) }
        let file = video.appendingPathComponent("clip.mp4")
        try await Self.makeVideo().write(to: file)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFrontRegardless()
        defer {
            window.orderOut(nil)
            window.close()
        }
        let engine = WebKitEngine(fileInput: NoFileInput(), stores: .inMemory(), downloadsDirectory: video)
        let page = engine.makeWebKitTab()
        defer { page.close() }
        window.contentView = page.contentView

        page.load(file)
        try await Self.until("the local video plays") {
            let time = try? await page.evaluate("document.querySelector('video')?.currentTime ?? 0", world: .page, gesture: .agent)
            if case .number(let seconds)? = time { return seconds > 0 }
            return false
        }
        #expect(page.state.url == file, "the tab shows \(page.state.url?.absoluteString ?? "nothing")")
    }

    @Test func onlyWebVideosPlayInTheTab() throws {
        func plays(_ text: String) throws -> Bool { RemoteVideoPage.plays(try #require(URL(string: text))) }
        #expect(try plays("https://raw.githubusercontent.com/o/r/b/reel.mp4"))
        #expect(try plays("http://example.com/a/clip.WEBM?x=1"))
        #expect(try !plays("https://example.com/archive.zip"))
        #expect(try !plays("file:///tmp/clip.mp4"))
        #expect(RemoteVideoPage.html(for: try #require(URL(string: "https://e.com/a.mp4?a=1&b=2"))).contains("a.mp4?a=1&amp;b=2"))
    }

    /// One second of a 64-pixel H.264 video, as an .mp4. Off the main actor: it writes and reads a file.
    @concurrent private nonisolated static func makeVideo() async throws -> Data {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("cn-remote-video-\(UUID().uuidString.prefix(8).lowercased()).mp4")
        defer { try? FileManager.default.removeItem(at: file) }
        let writer = try AVAssetWriter(outputURL: file, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
        #expect(writer.startWriting(), "the writer did not start: \(String(describing: writer.error))")
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<10 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(10)) }
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA, nil, &buffer)
            adaptor.append(try #require(buffer), withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 10))
        }
        input.markAsFinished()
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in writer.finishWriting { done.resume() } }
        return try Data(contentsOf: file)
    }

    private static func until(_ what: String, _ done: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(30)
        while !(await done()) {
            guard ContinuousClock.now < deadline else {
                Issue.record("timed out: \(what)")
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    /// Records whether the tab started a download (one the gate refused does not count).
    final class Intents: BrowserTabDelegate {
        private(set) var downloaded = false
        func browserTab(_ tab: any BrowserTab, didRequest intent: BrowserTabIntent) {
            guard case .download(let download) = intent else { return }
            if case .blocked = download.status { return }
            downloaded = true
        }
    }

    /// Serves `/a`, which links to `/b`, which links to `/reel.mp4`; `/c`, a form that posts to
    /// `/reel.mp4`; and `video` at `/reel.mp4` (for any method) the
    /// way raw.githubusercontent.com does: a generic file, never sniffed, in byte ranges on request.
    nonisolated final class VideoServer: @unchecked Sendable {
        private let listener: NWListener
        private let video: Data
        private let queue = DispatchQueue(label: "cn-remote-video")
        private(set) var port: UInt16 = 0
        private var ready: Bool?

        private init(listener: NWListener, video: Data) {
            self.listener = listener
            self.video = video
        }

        static func start(video: Data) async throws -> VideoServer {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
            let server = VideoServer(listener: try NWListener(using: parameters), video: video)
            server.listener.newConnectionHandler = { [server] connection in server.serve(connection) }
            let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
                // The handler runs on the server's queue only, so it reads and sets `ready` there.
                server.listener.stateUpdateHandler = { [server] state in
                    guard server.ready == nil else { return }
                    switch state {
                    case .ready:
                        server.ready = true
                        continuation.resume(returning: server.listener.port?.rawValue ?? 0)
                    case .failed(let error):
                        server.ready = false
                        continuation.resume(throwing: error)
                    default: break
                    }
                }
                server.listener.start(queue: server.queue)
            }
            server.port = port
            return server
        }

        func url(_ path: String) -> URL {
            URL(string: "http://127.0.0.1:\(port)\(path)")! // swiftlint:disable:this force_unwrapping
        }

        func stop() { listener.cancel() }

        /// The bytes a `Range: bytes=a-b` header asks for (the whole file without one).
        private func range(_ request: String) -> ClosedRange<Int>? {
            let last = video.count - 1
            guard let line = request.split(separator: "\r\n").first(where: { $0.lowercased().hasPrefix("range: bytes=") })
            else { return nil }
            let bounds = line.dropFirst("range: bytes=".count).split(separator: "-", omittingEmptySubsequences: false)
            let start = Int(bounds.first ?? "") ?? 0
            let end = min(bounds.count > 1 ? Int(bounds[1]) ?? last : last, last)
            return start <= end ? start...end : nil
        }

        private func serve(_ connection: NWConnection) {
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [self] data, _, _, _ in
                let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                let path = request.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
                if let page = ["/a": "<title>a</title><a href='/b'>b</a>", "/b": "<title>b</title><a href='/reel.mp4'>reel</a>",
                              "/c": "<title>c</title><form method='post' action='/reel.mp4'><input name='q' value='1'></form>"][path] {
                    let head = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: \(page.utf8.count)\r\nConnection: close\r\n\r\n"
                    connection.send(content: Data((head + page).utf8), completion: .contentProcessed { _ in connection.cancel() })
                    return
                }
                let part = range(request)
                let bytes = part.map { video.subdata(in: $0.lowerBound..<($0.upperBound + 1)) } ?? video
                var head = part.map { "HTTP/1.1 206 Partial Content\r\nContent-Range: bytes \($0.lowerBound)-\($0.upperBound)/\(video.count)\r\n" }
                    ?? "HTTP/1.1 200 OK\r\n"
                head += "Content-Type: application/octet-stream\r\nX-Content-Type-Options: nosniff\r\nAccept-Ranges: bytes\r\n"
                    + "Content-Length: \(bytes.count)\r\nConnection: close\r\n\r\n"
                connection.send(content: Data(head.utf8) + bytes, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
    }
}

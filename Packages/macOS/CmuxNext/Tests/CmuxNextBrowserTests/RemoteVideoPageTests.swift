import AppKit
import AVFoundation
@testable import CmuxNextBrowser
import Foundation
import Network
import Testing

/// ask-76f83a7020 (Leo: "id like to be able to watch .mp4s direclty in cmux next"): a web .mp4
/// whose server sends it as a generic file, as raw.githubusercontent.com sends the nightly reel
/// (`application/octet-stream`, `nosniff`), plays in the WebKit tab at its own address instead of
/// downloading. Runs a real WebKit page against a local server that answers range requests.
@MainActor @Suite(.serialized, .timeLimit(.minutes(2))) struct RemoteVideoPageTests {
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
        let page = WebKitEngine().makeWebKitTab()
        defer { page.close() }
        page.delegate = intents
        window.contentView = page.contentView
        let reel = server.url("/reel.mp4")
        page.load(reel)

        try await Self.until("the video has its metadata") {
            let ready = try? await page.evaluate("(document.querySelector('video')?.readyState ?? 0) >= 1", world: .page)
            return ready == .bool(true)
        }
        #expect(page.state.url == reel, "the tab shows \(page.state.url?.absoluteString ?? "nothing")")
        #expect(!intents.downloaded, "the video downloaded")
    }

    @Test func onlyWebVideosPlayInTheTab() throws {
        func plays(_ text: String) throws -> Bool { RemoteVideoPage.plays(try #require(URL(string: text))) }
        #expect(try plays("https://raw.githubusercontent.com/o/r/b/reel.mp4"))
        #expect(try plays("http://example.com/a/clip.WEBM?x=1"))
        #expect(try !plays("https://example.com/archive.zip"))
        #expect(try !plays("file:///tmp/clip.mp4"))
        #expect(RemoteVideoPage.html(for: try #require(URL(string: "https://e.com/a.mp4?a=1&b=2"))).contains("a.mp4?a=1&amp;b=2"))
    }

    /// One second of a 64-pixel H.264 video, as an .mp4.
    private static func makeVideo() async throws -> Data {
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

    /// Records whether the tab handed a download to the app.
    final class Intents: BrowserTabDelegate {
        private(set) var downloaded = false
        func browserTab(_ tab: any BrowserTab, didRequest intent: BrowserTabIntent) {
            if case .download = intent { downloaded = true }
        }
    }

    /// Serves `video` at any path the way raw.githubusercontent.com does: a generic file, never
    /// sniffed, in byte ranges on request.
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

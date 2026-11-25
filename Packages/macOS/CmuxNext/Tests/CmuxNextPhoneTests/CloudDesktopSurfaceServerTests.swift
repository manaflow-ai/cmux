import CoreVideo
import Foundation
import Network
import Testing
@testable import CmuxNextPhone

/// The Mac side of a phone viewing a Cloud desktop (cmux-mobile-host `surface.rs`, `c~` tabs):
/// the same `sf/1` source as a simulator, frames from a feed, input dropped.
@MainActor
@Suite struct CloudDesktopSurfaceServerTests {
    /// A feed the test drives by hand.
    @MainActor
    final class FakeFeed {
        var frame: (@MainActor (CVPixelBuffer) -> Void)?
        var ended: (@MainActor (String) -> Void)?
        var stops = 0

        var feed: SurfaceFrameFeed {
            SurfaceFrameFeed(start: { [self] frame, ended in
                self.frame = frame
                self.ended = ended
            }, stop: { [self] in stops += 1 })
        }
    }

    /// hostd's end of the loopback connection.
    @MainActor
    final class Hostd {
        let connection: NWConnection
        var wire = SurfaceSourceWire()
        let frames: AsyncStream<SurfaceSourceWire.Frame>
        let sink: AsyncStream<SurfaceSourceWire.Frame>.Continuation

        init(port: UInt16) {
            connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port) ?? .any, using: .tcp)
            (frames, sink) = AsyncStream.makeStream(of: SurfaceSourceWire.Frame.self)
            connection.start(queue: .main)
            receive()
        }

        private func receive() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [self] data, _, complete, error in
                MainActor.assumeIsolated {
                    if let data { wire.append(data) }
                    while let frame = try? wire.next() { sink.yield(frame) }
                    if complete || error != nil { return sink.finish() }
                    receive()
                }
            }
        }

        func send(_ object: [String: Any]) {
            connection.send(content: SurfaceSourceWire.json(object), completion: .contentProcessed { _ in })
        }
    }

    func buffer(width: Int, height: Int) throws -> CVPixelBuffer {
        var made: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()] as CFDictionary
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attributes, &made)
        return try #require(made)
    }

    @Test func framesStreamAfterTheHelloAndInputIsDropped() async throws {
        let fake = FakeFeed()
        let server = CloudDesktopSurfaceServer(feed: fake.feed, label: "vm-test")
        let port = try await server.start()
        // The desktop's first frame can come before hostd connects; it is shown after the hello.
        let first = try buffer(width: 1280, height: 800)
        fake.frame?(first)
        let hostd = Hostd(port: port)
        hostd.send(["t": "hello", "secret": server.secret])
        var lines = hostd.frames.makeAsyncIterator()
        #expect(await lines.next() == .json(["t": .string("size"), "width": .number(1280), "height": .number(800)]))
        #expect(await lines.next() == .json(["t": .string("damage")]))
        // A phone's touch, text, key or button never reaches the feed, and the source keeps running.
        hostd.send(["t": "touch", "phase": "began", "x": 0.5, "y": 0.5])
        hostd.send(["t": "text", "text": "rm -rf /"])
        hostd.send(["t": "key", "key": "Enter", "down": true])
        hostd.send(["t": "button", "button": "home"])
        // Frames coalesce: a second frame before an encode raises no second damage; a hide and show does.
        let second = try buffer(width: 1280, height: 800)
        fake.frame?(second)
        hostd.send(["t": "visible", "visible": false])
        hostd.send(["t": "visible", "visible": true])
        #expect(await lines.next() == .json(["t": .string("damage")]))
        #expect(server.isRunning)
        server.stop()
        #expect(fake.stops == 1)
        hostd.connection.cancel()
    }

    @Test func aWrongSecretIsRefused() async throws {
        let fake = FakeFeed()
        let server = CloudDesktopSurfaceServer(feed: fake.feed, label: "vm-test")
        let port = try await server.start()
        let hostd = Hostd(port: port)
        hostd.send(["t": "hello", "secret": "nope"])
        var lines = hostd.frames.makeAsyncIterator()
        #expect(await lines.next() == .json(["t": .string("error"), "message": .string("unauthorized")]))
        server.stop()
        hostd.connection.cancel()
    }

    @Test func theSourceEndsWhenTheDesktopStreamEnds() async throws {
        let fake = FakeFeed()
        let server = CloudDesktopSurfaceServer(feed: fake.feed, label: "vm-test")
        var ends = 0
        server.onEnd = { ends += 1 }
        _ = try await server.start()
        fake.ended?("the desktop stream ended")
        #expect(!server.isRunning)
        #expect(ends == 1)
        // Stopping again is a no-op: onEnd runs once.
        server.stop()
        #expect(ends == 1)
    }

    @Test func aStopWhileStartingNeverHangsTheStart() async throws {
        let server = CloudDesktopSurfaceServer(feed: SurfaceFrameFeed(start: { _, ended in ended("no desktop") }, stop: {}),
                                               label: "vm-test")
        await #expect(throws: CloudDesktopSurfaceServer.Failure.self) { _ = try await server.start() }
        #expect(!server.isRunning)
    }
}

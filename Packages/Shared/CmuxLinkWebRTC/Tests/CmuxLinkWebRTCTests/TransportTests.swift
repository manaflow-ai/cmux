import CmuxLink
import CmuxLinkSignaling
@_spi(Testing) import CmuxLinkWebRTC
import CoreVideo
import Foundation
import os
import Testing

extension LiveWebRTCTests {
@Suite("WebRTC transport")
struct TransportTests {
    static let reliable = TransportLane(reliability: .reliableOrdered, priority: .render)
    static let bulk = TransportLane(reliability: .reliableOrdered, priority: .bulk)

    @Test("loopback host candidates classify as p2p on the webrtc carrier")
    func pathIsP2P() async throws {
        let pair = await WebRTCPair()
        let (dialer, host) = try await within { try await pair.connect() }
        #expect(await dialer.path == LinkPath(kind: .p2p, carrier: .webrtc))
        #expect(await host.path == LinkPath(kind: .p2p, carrier: .webrtc))
        #expect(dialer.capabilities == .stream)
        await dialer.close()
        await pair.stop()
    }

    @Test("frames keep order per lane across two lanes and 256 KiB frames pass")
    func lanesAndLargeFrames() async throws {
        let pair = await WebRTCPair()
        let (dialer, host) = try await within { try await pair.connect() }
        let big = Data(repeating: 7, count: TransportCapabilities.stream.maxFrameBytes)
        for index in 0..<50 {
            try await dialer.send(TransportFrame(lane: Self.reliable, bytes: Data("r\(index)".utf8)))
            try await dialer.send(TransportFrame(lane: Self.bulk, bytes: index == 25 ? big : Data("b\(index)".utf8)))
        }
        let frames = try await within { () -> [TransportFrame] in
            var frames: [TransportFrame] = []
            for await event in host.events {
                if case let .frame(frame) = event { frames.append(frame) }
                if frames.count == 100 { break }
            }
            return frames
        }
        let render = frames.filter { $0.lane == Self.reliable }.map { String(decoding: $0.bytes, as: UTF8.self) }
        #expect(render == (0..<50).map { "r\($0)" })
        let bulk = frames.filter { $0.lane == Self.bulk }
        #expect(bulk.count == 50)
        #expect(bulk[25].bytes == big)
        await #expect(throws: WebRTCTransportError.frameTooLarge(big.count + 1)) {
            try await dialer.send(TransportFrame(lane: Self.bulk, bytes: big + Data([0])))
        }
        await dialer.close()
        await pair.stop()
    }

    @Test("graceful close delivers everything before one closed(remote)")
    func gracefulClose() async throws {
        let pair = await WebRTCPair()
        let (dialer, host) = try await within { try await pair.connect() }
        let total = 300
        for index in 0..<total {
            try await dialer.send(TransportFrame(lane: index.isMultiple(of: 2) ? Self.reliable : Self.bulk, bytes: Data(count: 4096)))
        }
        async let closing: Void = dialer.close()
        let (frames, closes) = try await within { () -> (Int, [TransportCloseReason]) in
            var frames = 0
            var closes: [TransportCloseReason] = []
            for await event in host.events {
                switch event {
                case .frame: frames += 1
                case let .closed(reason): closes.append(reason)
                default: break
                }
            }
            return (frames, closes)
        }
        await closing
        #expect(frames == total)
        #expect(closes == [.remote])
        let dialerCloses = await closedReasons(dialer)
        #expect(dialerCloses == [.local])
        await pair.stop()
    }

    @Test("a dropped peer connection ends both transports with pathLost")
    func drop() async throws {
        let pair = await WebRTCPair()
        let (dialer, host) = try await within { try await pair.connect() }
        await pair.injector.dropAll()
        let hostCloses = try await within { await closedReasons(host) }
        let dialerCloses = try await within { await closedReasons(dialer) }
        #expect(hostCloses.count == 1)
        #expect(dialerCloses.count == 1)
        if case .pathLost = hostCloses.first {} else { Issue.record("host saw \(hostCloses)") }
        await #expect(throws: WebRTCTransportError.closed) {
            try await dialer.send(TransportFrame(lane: Self.reliable, bytes: Data("late".utf8)))
        }
        await pair.stop()
    }

    @Test("an ICE restart keeps the transport and its lanes")
    func iceRestart() async throws {
        let pair = await WebRTCPair()
        let (dialer, host) = try await within { try await pair.connect() }
        let (offers, offerSink) = AsyncStream.makeStream(of: Bool.self)
        pair.hub.setInterceptor { message in
            if case let .offer(_, restart, _, _) = message.payload { offerSink.yield(restart) }
            return message
        }
        try await dialer.send(TransportFrame(lane: Self.reliable, bytes: Data("before".utf8)))
        await dialer.restartICE()
        // The restart offer is signaled, answered, and ICE checks again on new credentials.
        let restartFlag = try await within { () -> Bool? in
            for await restart in offers { return restart }
            return nil
        }
        try await dialer.send(TransportFrame(lane: Self.reliable, bytes: Data("after".utf8)))
        let payloads = try await within { () -> [String] in
            var payloads: [String] = []
            for await event in host.events {
                if case let .frame(frame) = event { payloads.append(String(decoding: frame.bytes, as: UTF8.self)) }
                if case .closed = event { break }
                if payloads.count == 2 { break }
            }
            return payloads
        }
        #expect(restartFlag == true)
        #expect(payloads == ["before", "after"])
        await dialer.close()
        await pair.stop()
    }

    @Test("a host video track reaches the dialer and renders frames")
    func mediaTrack() async throws {
        let pair = await WebRTCPair()
        let (dialer, host) = try await within { try await pair.connect() }
        let descriptor = MediaTrackDescriptor(id: "trk_browser1", kind: .video, label: "browser/tab_9f2")
        let published = try await host.publishMediaTrack(descriptor)
        let pixels = PixelBox(buffer: try #require(Self.pixelBuffer(width: 64, height: 48)))
        let pusher = Task {
            var tick = 0
            while !Task.isCancelled {
                await published.push(MediaFrame(timestamp: .milliseconds(tick * 33), width: 64, height: 48, payload: .native(WebRTCPixelBufferBox(pixelBuffer: pixels.buffer))))
                tick += 1
                try? await Task.sleep(for: .milliseconds(33))
            }
        }
        defer { pusher.cancel() }
        let handle = try await within { () -> MediaTrackHandle? in
            for await event in dialer.events {
                if case let .mediaTrack(handle) = event { return handle }
            }
            return nil
        }
        let received = try #require(handle)
        #expect(received.descriptor == descriptor)
        let sink = FrameSink()
        await received.attach(sink)
        let frame = try await within { await sink.first() }
        #expect(frame.width == 64 && frame.height == 48)
        await dialer.close()
        await pair.stop()
    }

    @Test("audio tracks are refused")
    func audioRefused() async throws {
        let pair = await WebRTCPair()
        let (dialer, host) = try await within { try await pair.connect() }
        await #expect(throws: WebRTCTransportError.mediaKindUnsupported(.audio)) {
            _ = try await host.publishMediaTrack(MediaTrackDescriptor(id: "a", kind: .audio, label: "voice"))
        }
        await dialer.close()
        await pair.stop()
    }

    static func pixelBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, attributes, &buffer)
        return buffer
    }
}
}

/// Drains a transport's events and returns its close reasons.
func closedReasons(_ transport: WebRTCTransport) async -> [TransportCloseReason] {
    var reasons: [TransportCloseReason] = []
    for await event in transport.events {
        if case let .closed(reason) = event { reasons.append(reason) }
    }
    return reasons
}

struct PixelBox: @unchecked Sendable {
    let buffer: CVPixelBuffer
}

final class FrameSink: MediaFrameSink, @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [MediaFrame] = []
    private var waiter: CheckedContinuation<MediaFrame, Never>?

    func receive(_ frame: MediaFrame) {
        let waiter = lock.withLock { () -> CheckedContinuation<MediaFrame, Never>? in
            frames.append(frame)
            defer { self.waiter = nil }
            return self.waiter
        }
        waiter?.resume(returning: frame)
    }

    func first() async -> MediaFrame {
        await withCheckedContinuation { continuation in
            let ready = lock.withLock { () -> MediaFrame? in
                if let first = frames.first { return first }
                waiter = continuation
                return nil
            }
            if let ready { continuation.resume(returning: ready) }
        }
    }
}

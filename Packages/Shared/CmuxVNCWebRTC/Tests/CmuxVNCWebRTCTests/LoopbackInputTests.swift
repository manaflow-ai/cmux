import CmuxVNC
@testable import CmuxVNCWebRTC
import CoreGraphics
import CoreVideo
import Foundation
import Testing

/// A viewer's input frame is untrusted: the loopback backend turns any of its numbers into RFB
/// PointerEvents inside the streamed display. Before p10-stability-023 a coordinate of 1e300
/// trapped in apply's Int conversion and a scroll of Int.min trapped in abs(_:).
struct LoopbackInputTests {
    @Test(.timeLimit(.minutes(1)))
    func hostileInputBecomesPointerEventsInsideTheDisplay() async throws {
        let server = LoopbackServer(width: 64, height: 32)
        let backend = VNCLoopbackBackend(target: VNCEndpoint(host: "loopback.invalid", port: 5900),
                                         credentials: VNCCredentials(), transport: server) { _ in }
        defer { backend.stop() }
        let (displays, sink) = AsyncStream.makeStream(of: [CGSize].self)
        try await backend.start(frame: { _, _ in }, displays: { sizes, _ in sink.yield(sizes) })
        var reported = displays.makeAsyncIterator()
        let first = await reported.next()
        #expect(first == [CGSize(width: 64, height: 32)])

        backend.handle(ScreenInput(t: "move", x: 1e300, y: -1e300, b: 0))
        backend.handle(ScreenInput(t: "scroll", x: 0.5, y: 0.5, dx: .min, dy: .min))
        let events = await server.pointerSends(3)

        // The move points at the last column, never one past it.
        #expect(events[0] == [5, 0, 0, 63, 0, 0])
        #expect(events[1] == [5, 0, 0, 32, 0, 16])
        // Int.min clicks are 50 wheel-down then 50 wheel-right clicks, each a press and a release.
        let scroll = events[2]
        #expect(scroll.count == 200 * 6)
        let masks = stride(from: 0, to: scroll.count, by: 6).map { scroll[$0 + 1] }
        let wheelDown = VNCButtons.wheelDown.rawValue, wheelRight = VNCButtons.wheelRight.rawValue
        let downClicks: [UInt8] = Array(repeating: [wheelDown, 0], count: 50).flatMap { $0 }
        let rightClicks: [UInt8] = Array(repeating: [wheelRight, 0], count: 50).flatMap { $0 }
        #expect(masks == downClicks + rightClicks)
    }

    @Test func aPointerMessageMapsToTheDisplaysPixels() {
        let display = CGRect(x: 1920, y: 0, width: 1024, height: 768)
        #expect(pixel(x: 1e300, y: -1e300, in: display) == [2943, 0])
        #expect(pixel(x: 1, y: 1, in: display) == [2943, 767])
        #expect(pixel(x: 0.5, y: 0.25, in: display) == [2432, 192])
        #expect(pixel(x: .nan, y: .infinity, in: display) == [1920, 0])
        #expect(pixel(x: 1, y: 1, in: .zero) == [0, 0])
    }

    private func pixel(x: Double, y: Double, in display: CGRect) -> [Int] {
        let pixel = ScreenInput(t: "move", x: x, y: y).pixel(in: display)
        return [pixel.x, pixel.y]
    }
}

/// A VNC server for one session: RFB 3.8 with no security, a white `width` x `height`
/// framebuffer sent once as a Raw update, then nothing until the client closes. It keeps each
/// PointerEvent send.
// crash-allow: every stored property is read and written only while `lock` is held.
final class LoopbackServer: RFBTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [UInt8]
    private var closed = false
    private var reader: CheckedContinuation<[UInt8], any Error>?
    private var pointers: [[UInt8]] = []
    private var waiter: (count: Int, continuation: CheckedContinuation<[[UInt8]], Never>)?

    init(width: Int, height: Int) {
        func u16(_ value: Int) -> [UInt8] { [UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)] }
        var bytes = Array("RFB 003.008\n".utf8) + [1, 1] + [0, 0, 0, 0]
        bytes += u16(width) + u16(height) + [32, 24, 0, 1, 0, 255, 0, 255, 0, 255, 16, 8, 0, 0, 0, 0]
        bytes += [0, 0, 0, 4] + Array("loop".utf8)
        bytes += [0, 0] + u16(1) + u16(0) + u16(0) + u16(width) + u16(height) + [0, 0, 0, 0]
        bytes += [UInt8](repeating: 0xFF, count: width * height * 4)
        pending = bytes
    }

    func open() async throws {}

    func receive() async throws -> [UInt8] {
        try await withCheckedThrowingContinuation { continuation in
            let ready: Result<[UInt8], any Error>? = lock.withLock {
                if !pending.isEmpty {
                    defer { pending = [] }
                    return .success(pending)
                }
                if closed { return .failure(RFBError.connectionClosed) }
                reader = continuation
                return nil
            }
            if let ready { continuation.resume(with: ready) }
        }
    }

    func send(_ bytes: [UInt8]) async throws {
        guard bytes.first == 5 else { return }
        let done = lock.withLock { () -> (CheckedContinuation<[[UInt8]], Never>, [[UInt8]])? in
            pointers.append(bytes)
            guard let waiter, pointers.count >= waiter.count else { return nil }
            self.waiter = nil
            return (waiter.continuation, pointers)
        }
        if let done { done.0.resume(returning: done.1) }
    }

    func close() {
        let pendingReader = lock.withLock { () -> CheckedContinuation<[UInt8], any Error>? in
            closed = true
            defer { reader = nil }
            return reader
        }
        pendingReader?.resume(throwing: RFBError.connectionClosed)
    }

    /// The first `count` PointerEvent sends, once they have all arrived.
    func pointerSends(_ count: Int) async -> [[UInt8]] {
        await withCheckedContinuation { continuation in
            let ready = lock.withLock { () -> [[UInt8]]? in
                if pointers.count >= count { return pointers }
                waiter = (count, continuation)
                return nil
            }
            if let ready { continuation.resume(returning: ready) }
        }
    }
}

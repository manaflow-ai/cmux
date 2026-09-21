import CmuxControlSocket
import CmuxSettings
import Darwin
import Foundation
import os
import Testing

/// Records the descriptors the accept path could not buffer and answers them
/// through the overload responder, as the app's composition root does.
private final class DroppedConnectionSink: Sendable {
    private let dropped = OSAllocatedUnfairLock(initialState: [Int32]())
    let responder = ControlOverloadResponder(
        strings: ControlOverloadResponder.Strings(message: "cmux is busy")
    )

    func handle(socket: Int32) {
        dropped.withLock { $0.append(socket) }
        responder.reject(socket: socket, reason: .acceptBufferFull)
    }

    var droppedCount: Int {
        dropped.withLock { $0.count }
    }
}

/// A CLI-shaped client: connect, write one request line, read until EOF.
private final class DroppedClient {
    private var fd: Int32

    init(path: String) throws {
        fd = try UnixSocketFixture.connectClient(to: path)
    }

    func send(_ line: String) {
        let bytes = Array(line.utf8)
        bytes.withUnsafeBufferPointer { buffer in
            _ = Darwin.write(fd, buffer.baseAddress, buffer.count)
        }
    }

    /// Bounded poll of the real EOF condition, never a fixed sleep.
    func readUntilEOF(timeout: TimeInterval = 5) -> String {
        var collected = [UInt8]()
        var buffer = [UInt8](repeating: 0, count: 4096)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN | POLLHUP), revents: 0)
            guard poll(&descriptor, 1, 100) > 0 else { continue }
            let count = buffer.withUnsafeMutableBufferPointer { raw in
                Darwin.read(fd, raw.baseAddress, raw.count)
            }
            if count > 0 {
                collected.append(contentsOf: buffer[0..<count])
                continue
            }
            if count == 0 || (count < 0 && errno != EAGAIN && errno != EINTR) {
                break
            }
        }
        return String(decoding: collected, as: UTF8.self)
    }

    deinit {
        if fd >= 0 {
            close(fd)
            fd = -1
        }
    }
}

/// When the accept buffer is full, the server hands the connection to the
/// host instead of closing it, so the client still receives a structured
/// `overloaded` error rather than EPIPE (#13369).
@MainActor
@Suite("SocketControlServer accept-buffer drops")
struct SocketControlServerConnectionDropTests {
    @Test func fullAcceptBufferHandsTheConnectionToTheHostForAStructuredReply() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("scs-drop-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let socketPath = directory.appendingPathComponent("s.sock").path
        let sink = DroppedConnectionSink()
        let server = SocketControlServer(
            initialSocketPath: socketPath,
            // No buffered connections and no consumer: every accept is dropped.
            maximumBufferedConnections: 0,
            notificationCenter: NotificationCenter(),
            events: SocketControlServerEvents(
                breadcrumb: { _, _ in },
                failure: { _, _, _, _ in },
                listenerDidStart: { _, _ in },
                recordLastSocketPath: { _ in },
                pathMissingDetected: { _, _ in },
                rearmRequested: { _, _, _, _ in },
                connectionDropped: { socket, _ in sink.handle(socket: socket) }
            )
        )
        defer { server.stop() }
        #expect(server.start(socketPath: socketPath, accessMode: .cmuxOnly))

        let client = try DroppedClient(path: socketPath)
        client.send(#"{"id":"drop-1","method":"system.ping","params":{}}"# + "\n")

        let reply = client.readUntilEOF()
        let object = try #require(
            JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any]
        )
        #expect(object["id"] as? String == "drop-1")
        let error = try #require(object["error"] as? [String: Any])
        #expect(error["code"] as? String == "overloaded")
        let data = try #require(error["data"] as? [String: Any])
        #expect(data["reason"] as? String == "accept_buffer_full")
        #expect(sink.droppedCount == 1)
    }
}

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
    /// The client writes its line before the responder reads, so the reply
    /// never waits on this deadline. It is generous only so a runner that
    /// starves the responder's reader for seconds cannot turn a correct reply
    /// into a bare close.
    let responder = ControlOverloadResponder(
        strings: ControlOverloadResponder.Strings(message: "cmux is busy"),
        configuration: ControlOverloadResponder.Configuration(readDeadlineMilliseconds: 30_000)
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
private final class DroppedClient: Sendable {
    private let fd: Int32

    init(path: String) throws {
        fd = try UnixSocketFixture.connectClient(to: path)
    }

    func send(_ line: String) {
        let bytes = Array(line.utf8)
        bytes.withUnsafeBufferPointer { buffer in
            _ = Darwin.write(fd, buffer.baseAddress, buffer.count)
        }
    }

    /// Waits for the server side to close, off the main actor.
    func readUntilEOF() async -> (text: String, sawEOF: Bool) {
        await UnixSocketFixture.readUntilEOF(fd)
    }

    deinit {
        close(fd)
    }
}

/// When the accept buffer is full, the server hands the connection to the
/// host instead of closing it, so the client still receives a structured
/// `overloaded` error rather than EPIPE (#13369). The suite runs on the main
/// actor because the server does, so it awaits the reply rather than polling
/// for it on the main thread.
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

        let reply = await client.readUntilEOF()
        #expect(reply.sawEOF)
        let object = try #require(
            JSONSerialization.jsonObject(with: Data(reply.text.utf8)) as? [String: Any]
        )
        #expect(object["id"] as? String == "drop-1")
        let error = try #require(object["error"] as? [String: Any])
        #expect(error["code"] as? String == "overloaded")
        let data = try #require(error["data"] as? [String: Any])
        #expect(data["reason"] as? String == "accept_buffer_full")
        #expect(sink.droppedCount == 1)
    }
}

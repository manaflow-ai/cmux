import CmuxVNC
import Foundation

/// The viewer side: an `RFBTransport` whose bytes ride a WebRTC data channel
/// to a `cmux-vnc-host`, which pipes them to the Mac's VNC server. `open()`
/// signals through the room, offers, and returns when the channel opens.
// crash-allow: mutable state (link, socket, inbox, tasks, closed) is read and written only under `lock`.
public final class WebRTCRFBTransport: RFBTransport, @unchecked Sendable {
    // @unchecked: mutable state is behind `lock`.
    private let pairing: VNCPairing
    private let lock = NSLock()
    private var link: VNCPeerLink?
    private var socket: SignalSocket?
    private var inbox: AsyncStream<Data>.Iterator?
    private var inboxSink: AsyncStream<Data>.Continuation?
    private var tasks: [Task<Void, Never>] = []
    private var closed = false

    public init(pairing: VNCPairing) {
        self.pairing = pairing
    }

    public func open() async throws {
        let ice = try await SignalSocket.iceServers(pairing)
        let socket = SignalSocket(pairing: pairing, role: "viewer")
        let link = try VNCPeerLink(iceServers: ice)
        let (stream, sink) = AsyncStream.makeStream(of: Data.self, bufferingPolicy: .unbounded)
        guard lock.withLock({ () -> Bool in
            guard !closed else { return false }
            self.link = link
            self.socket = socket
            inbox = stream.makeAsyncIterator()
            inboxSink = sink
            return true
        }) else { throw RFBError.connectionClosed }

        let opened = OpenSignal()
        // Peer events: candidates out, bytes in.
        let peerTask = Task {
            for await event in link.events {
                switch event {
                case let .candidate(message): try? await socket.send(message)
                case .open: opened.fire(nil)
                case let .message(data): sink.yield(data)
                case .closed:
                    opened.fire(RFBError.connectionClosed)
                    sink.finish()
                case .path, .video:
                    break
                }
            }
            sink.finish()
        }
        // Signaling: offer when the host is there, then the answer and its candidates.
        let signalTask = Task {
            do {
                for try await message in socket.messages() {
                    switch message.type {
                    case "hello" where message.peer == true, "peer-joined":
                        let sdp = try await link.offer()
                        try await socket.send(SignalMessage(type: "offer", sdp: sdp))
                    case "hello":
                        break // waits for the host to join
                    case "answer":
                        if let sdp = message.sdp { try await link.accept(answer: sdp) }
                    case "candidate":
                        await link.add(candidate: message)
                    case "peer-left":
                        opened.fire(RFBError.transport("the Mac's cmux-vnc-host left"))
                        link.close()
                    default:
                        break
                    }
                }
            } catch {
                opened.fire(RFBError.transport("signaling: \(error.localizedDescription)"))
            }
        }
        lock.withLock { tasks = [peerTask, signalTask] }
        try await opened.wait(timeout: 30)
    }

    public func receive() async throws -> [UInt8] {
        guard var iterator = lock.withLock({ inbox }) else { throw RFBError.connectionClosed }
        // One reader (the RFB session task) at a time.
        let next = await iterator.next()
        lock.withLock { inbox = iterator }
        guard let next else { throw RFBError.connectionClosed }
        return [UInt8](next)
    }

    public func send(_ bytes: [UInt8]) async throws {
        guard let link = lock.withLock({ link }) else { throw RFBError.connectionClosed }
        do { try await link.send(Data(bytes)) } catch { throw RFBError.connectionClosed }
    }

    public func close() {
        let (link, socket, tasks, sink) = lock.withLock { () -> (VNCPeerLink?, SignalSocket?, [Task<Void, Never>], AsyncStream<Data>.Continuation?) in
            closed = true
            defer { self.tasks.removeAll() }
            return (self.link, self.socket, self.tasks, inboxSink)
        }
        link?.close()
        socket?.close()
        sink?.finish()
        for task in tasks { task.cancel() }
    }
}

/// Resolves once: the channel opened (nil) or the attempt failed.
// crash-allow: `result` and `waiter` are read and written only under `lock`; the waiter resumes outside it, once.
final class OpenSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var result: (any Error)??
    private var waiter: CheckedContinuation<Void, any Error>?

    func fire(_ error: (any Error)?) {
        let waiter = lock.withLock { () -> CheckedContinuation<Void, any Error>? in
            guard result == nil else { return nil }
            result = .some(error)
            defer { self.waiter = nil }
            return self.waiter
        }
        if let error { waiter?.resume(throwing: error) } else { waiter?.resume() }
    }

    func wait(timeout seconds: Double) async throws {
        let timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds)) // connection deadline, not synchronization
            self?.fire(RFBError.transport("no WebRTC path to the Mac in \(Int(seconds)) s"))
        }
        defer { timer.cancel() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let done = lock.withLock { () -> (any Error)?? in
                if let result { return .some(result) }
                waiter = continuation
                return nil
            }
            if let done {
                if let error = done { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }
}

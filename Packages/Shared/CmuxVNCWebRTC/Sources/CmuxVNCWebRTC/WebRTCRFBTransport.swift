import CmuxSafeConcurrency
import CmuxVNC
import Foundation

/// The viewer side: an `RFBTransport` whose bytes ride a WebRTC data channel
/// to a `cmux-vnc-host`, which pipes them to the Mac's VNC server. `open()`
/// signals through the room, offers, and returns when the channel opens.
public final class WebRTCRFBTransport: RFBTransport {
    private let pairing: VNCPairing

    private struct State: Sendable {
        var link: VNCPeerLink?
        var socket: SignalSocket?
        var inbox: ByteInbox?
        var tasks: [Task<Void, Never>] = []
        var closed = false
    }

    private let state = Mutex(State())

    public init(pairing: VNCPairing) {
        self.pairing = pairing
    }

    public func open() async throws {
        let ice = try await SignalSocket.iceServers(pairing)
        let socket = SignalSocket(pairing: pairing, role: "viewer")
        let link = try VNCPeerLink(iceServers: ice)
        let inbox = ByteInbox()
        let adopted: Bool = state.withLock { state in
            guard !state.closed else { return false }
            state.link = link
            state.socket = socket
            state.inbox = inbox
            return true
        }
        guard adopted else { throw RFBError.connectionClosed }

        let opened = OpenSignal()
        // Peer events: candidates out, bytes in.
        let peerTask = Task {
            for await event in link.events {
                switch event {
                case let .candidate(message): try? await socket.send(message)
                case .open: opened.fire(nil)
                case let .message(data): inbox.yield(data)
                case .closed:
                    opened.fire(RFBError.connectionClosed)
                    inbox.finish()
                case .path, .video:
                    break
                }
            }
            inbox.finish()
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
        state.withLock { $0.tasks = [peerTask, signalTask] }
        try await opened.wait(timeout: 30)
    }

    public func receive() async throws -> [UInt8] {
        guard let inbox = state.withLock({ $0.inbox }) else { throw RFBError.connectionClosed }
        guard let next = await inbox.next() else { throw RFBError.connectionClosed }
        return [UInt8](next)
    }

    public func send(_ bytes: [UInt8]) async throws {
        guard let link = state.withLock({ $0.link }) else { throw RFBError.connectionClosed }
        do { try await link.send(Data(bytes)) } catch { throw RFBError.connectionClosed }
    }

    public func close() {
        let closing: State = state.withLock { state in
            state.closed = true
            defer { state.tasks.removeAll() }
            return state
        }
        closing.link?.close()
        closing.socket?.close()
        closing.inbox?.finish()
        for task in closing.tasks { task.cancel() }
    }
}

/// The data channel's bytes, in order, for one reader (the RFB session task):
/// libwebrtc's signaling thread yields, ``next()`` takes. A Sendable queue
/// because an `AsyncStream` iterator is not Sendable, so a Sendable transport
/// could not keep one between `receive()` calls.
final class ByteInbox: Sendable {
    private struct State: Sendable {
        /// Newest last.
        var incoming: [Data] = []
        /// Oldest last (`incoming` reversed, so taking one is `popLast`).
        var outgoing: [Data] = []
        var waiter: OnceContinuation<Data?, OnceContinuationError>?
        var finished = false

        mutating func take() -> Data? {
            if outgoing.isEmpty {
                outgoing = incoming.reversed()
                incoming.removeAll(keepingCapacity: true)
            }
            return outgoing.popLast()
        }
    }

    private let state = Mutex(State())

    func yield(_ data: Data) {
        let waiter: OnceContinuation<Data?, OnceContinuationError>? = state.withLock { state in
            guard !state.finished else { return nil }
            // A waiter is there only while nothing is queued, so the order holds.
            guard let waiter = state.waiter else {
                state.incoming.append(data)
                return nil
            }
            state.waiter = nil
            return waiter
        }
        waiter?.resume(returning: data)
    }

    /// No more bytes: the reader gets what is queued, then nil.
    func finish() {
        let waiter: OnceContinuation<Data?, OnceContinuationError>? = state.withLock { state in
            state.finished = true
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.resume(returning: nil)
    }

    /// The next bytes; nil after ``finish()`` once the queue is empty, or when
    /// the reading task is cancelled (which finishes the inbox, as cancelling
    /// an `AsyncStream`'s reader ends the stream). A second reader waiting at
    /// the same time gets nil.
    func next() async -> Data? {
        await withTaskCancellationHandler {
            // The inbox holds the waiter until a yield or finish; a dropped one reads as the end (nil).
            try? await withOnceContinuation { (continuation: OnceContinuation<Data?, OnceContinuationError>) in
                let ready: Data?? = state.withLock { state in
                    if let chunk = state.take() { return .some(chunk) }
                    if state.finished || state.waiter != nil { return .some(nil) }
                    state.waiter = continuation
                    return nil
                }
                if let ready { continuation.resume(returning: ready) }
            }
        } onCancel: {
            finish()
        }
    }
}

/// Resolves once: the channel opened (nil) or the attempt failed.
final class OpenSignal: Sendable {
    private struct State: Sendable {
        var result: (any Error)??
        var waiter: OnceContinuation<Void, any Error>?
    }

    private let state = Mutex(State())

    func fire(_ error: (any Error)?) {
        let waiter: OnceContinuation<Void, any Error>? = state.withLock { state in
            guard state.result == nil else { return nil }
            state.result = .some(error)
            defer { state.waiter = nil }
            return state.waiter
        }
        if let error { waiter?.resume(throwing: error) } else { waiter?.resume(returning: ()) }
    }

    func wait(timeout seconds: Double) async throws {
        let timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds)) // connection deadline, not synchronization
            self?.fire(RFBError.transport("no WebRTC path to the Mac in \(Int(seconds)) s"))
        }
        defer { timer.cancel() }
        try await withOnceThrowingContinuation { (continuation: OnceContinuation<Void, any Error>) in
            let done: (any Error)?? = state.withLock { state in
                if let result = state.result { return .some(result) }
                state.waiter = continuation
                return nil
            }
            if let done {
                if let error = done { continuation.resume(throwing: error) } else { continuation.resume(returning: ()) }
            }
        }
    }
}

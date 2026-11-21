internal import Darwin
internal import Foundation

/// A blocking wait, on a socket worker thread, for the first of three events:
/// the command's work completing, its time limit, or the socket client
/// closing its connection.
///
/// A legacy worker body that bridges async work (a Cloud VM call) blocks its
/// thread and holds one of the control socket's bounded slots. Without the
/// third event it kept that slot until its own limit (up to 17 minutes) even
/// after the client gave up and exited, so a burst of abandoned calls starved
/// every other command until the app relaunched
/// (<https://github.com/manaflow-ai/cmux/issues/48314>).
///
/// One kqueue carries both signals: an `EVFILT_USER` event that ``complete()``
/// triggers, and an edge-triggered `EVFILT_WRITE` on the client descriptor.
/// The write filter reports `EV_EOF` only when the peer has closed its read
/// side, which a full close does and a half-close (`shutdown(SHUT_WR)` after
/// sending the request) or a pipelined request does not, so a client still
/// waiting for its reply is never mistaken for one that left.
public final class ControlClientCompletionWait: @unchecked Sendable {
    /// Why ``wait(timeoutSeconds:)`` returned.
    public enum Outcome: Sendable, Equatable {
        /// ``complete()`` was called.
        case completed
        /// The time limit elapsed first.
        case timedOut
        /// The client closed its connection; nobody will read the answer.
        case clientClosed
    }

    private static let completionIdent: UInt = 1
    private let queue: Int32
    private let watchesClient: Bool

    /// - Parameter clientSocket: The connection's descriptor, owned by the
    ///   caller and open for the life of this wait; `nil` for an in-process
    ///   call, which waits only for completion or the limit.
    public init(clientSocket: Int32?) {
        queue = kqueue()
        var changes = [Self.event(ident: Self.completionIdent, filter: Int16(EVFILT_USER), flags: UInt16(EV_ADD | EV_CLEAR))]
        if let clientSocket, clientSocket >= 0 {
            changes.append(Self.event(ident: UInt(clientSocket), filter: Int16(EVFILT_WRITE), flags: UInt16(EV_ADD | EV_CLEAR)))
        }
        var registered = false
        if queue >= 0 {
            registered = kevent(queue, changes, Int32(changes.count), nil, 0, nil) == 0
        }
        watchesClient = registered && changes.count > 1
    }

    deinit {
        if queue >= 0 { close(queue) }
    }

    /// Ends the wait with ``Outcome/completed``. Safe from any thread, before
    /// or during the wait.
    public func complete() {
        guard queue >= 0 else { return }
        var trigger = Self.event(ident: Self.completionIdent, filter: Int16(EVFILT_USER), flags: 0)
        trigger.fflags = UInt32(NOTE_TRIGGER)
        _ = kevent(queue, [trigger], 1, nil, 0, nil)
    }

    /// Blocks until completion, the limit, or the client closing.
    ///
    /// - Parameter timeoutSeconds: The limit, or `nil` to wait without one.
    public func wait(timeoutSeconds: TimeInterval?) -> Outcome {
        guard queue >= 0 else { return .timedOut }
        let deadline = timeoutSeconds.map { DispatchTime.now().uptimeNanoseconds &+ UInt64(max(0, $0) * 1_000_000_000) }
        var events = [kevent](repeating: kevent(), count: 2)
        while true {
            var timeout = timespec()
            if let deadline {
                let now = DispatchTime.now().uptimeNanoseconds
                guard now < deadline else { return .timedOut }
                let remaining = deadline - now
                timeout.tv_sec = Int(remaining / 1_000_000_000)
                timeout.tv_nsec = Int(remaining % 1_000_000_000)
            }
            let count = withUnsafePointer(to: &timeout) { pointer in
                kevent(queue, nil, 0, &events, Int32(events.count), deadline == nil ? nil : pointer)
            }
            if count < 0 {
                if errno == EINTR { continue }
                return .timedOut
            }
            if count == 0 { return .timedOut }
            var clientClosed = false
            for event in events.prefix(Int(count)) {
                if event.filter == Int16(EVFILT_USER) { return .completed }
                if watchesClient, event.filter == Int16(EVFILT_WRITE), event.flags & UInt16(EV_EOF) != 0 {
                    clientClosed = true
                }
            }
            if clientClosed { return .clientClosed }
            // A writable edge with the peer still reading: keep waiting.
        }
    }

    private static func event(ident: UInt, filter: Int16, flags: UInt16) -> kevent {
        kevent(ident: ident, filter: filter, flags: flags, fflags: 0, data: 0, udata: nil)
    }
}

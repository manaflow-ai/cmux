internal import Darwin
internal import Dispatch

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
///
/// When the kqueue cannot be created or read (the process is out of
/// descriptors, say), the wait falls back to a plain semaphore: completion or
/// the limit, exactly the behavior before the client watch existed.
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
    private static let maximumTimeoutSeconds: Double = 1_000_000_000
    private let queue: Int32
    private let watchesClient: Bool
    /// Signalled by ``complete()`` alongside the kqueue trigger; the fallback.
    private let fallback = DispatchSemaphore(value: 0)

    /// - Parameter clientSocket: The connection's descriptor, owned by the
    ///   caller and open for the life of this wait; `nil` for an in-process
    ///   call, which waits only for completion or the limit.
    public init(clientSocket: Int32?) {
        let candidate = kqueue()
        var changes = [Self.event(ident: Self.completionIdent, filter: Int16(EVFILT_USER), flags: UInt16(EV_ADD | EV_CLEAR))]
        if let clientSocket, clientSocket >= 0 {
            changes.append(Self.event(ident: UInt(clientSocket), filter: Int16(EVFILT_WRITE), flags: UInt16(EV_ADD | EV_CLEAR)))
        }
        var registered = false
        if candidate >= 0 {
            registered = kevent(candidate, changes, Int32(changes.count), nil, 0, nil) == 0
            if !registered {
                close(candidate)
            }
        }
        queue = registered ? candidate : -1
        watchesClient = registered && changes.count > 1
    }

    deinit {
        if queue >= 0 { close(queue) }
    }

    /// Ends the wait with ``Outcome/completed``. Safe from any thread, before
    /// or during the wait.
    public func complete() {
        fallback.signal()
        guard queue >= 0 else { return }
        var trigger = Self.event(ident: Self.completionIdent, filter: Int16(EVFILT_USER), flags: 0)
        trigger.fflags = UInt32(NOTE_TRIGGER)
        _ = kevent(queue, [trigger], 1, nil, 0, nil)
    }

    /// Blocks until completion, the limit, or the client closing.
    ///
    /// A limit of zero checks once without blocking: the outcome reflects
    /// what has already happened (completion, a closed client) at the call.
    ///
    /// - Parameter timeoutSeconds: The limit, or `nil` to wait without one.
    ///   Negative and NaN limits count as zero; limits beyond about 31 years
    ///   are capped there.
    public func wait(timeoutSeconds: Double?) -> Outcome {
        let deadline = timeoutSeconds.map { seconds -> UInt64 in
            let bounded = seconds.isNaN ? 0 : min(max(0, seconds), Self.maximumTimeoutSeconds)
            return DispatchTime.now().uptimeNanoseconds &+ UInt64(bounded * 1_000_000_000)
        }
        guard queue >= 0 else { return waitWithoutClientWatch(until: deadline) }
        var events = Array(repeating: Darwin.kevent(), count: 2)
        while true {
            var timeout = timespec()
            if let deadline {
                // Past the deadline, still poll once with a zero timeout so
                // an event that already arrived is reported, not dropped.
                let now = DispatchTime.now().uptimeNanoseconds
                let remaining = now < deadline ? deadline - now : 0
                timeout.tv_sec = Int(remaining / 1_000_000_000)
                timeout.tv_nsec = Int(remaining % 1_000_000_000)
            }
            let count = withUnsafePointer(to: &timeout) { pointer in
                kevent(queue, nil, 0, &events, Int32(events.count), deadline == nil ? nil : pointer)
            }
            if count < 0 {
                if errno == EINTR { continue }
                return waitWithoutClientWatch(until: deadline)
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

    private func waitWithoutClientWatch(until deadline: UInt64?) -> Outcome {
        guard let deadline else {
            fallback.wait()
            return .completed
        }
        let result = fallback.wait(timeout: DispatchTime(uptimeNanoseconds: deadline))
        return result == .success ? .completed : .timedOut
    }

    private static func event(ident: UInt, filter: Int16, flags: UInt16) -> kevent {
        kevent(ident: ident, filter: filter, flags: flags, fflags: 0, data: 0, udata: nil)
    }
}

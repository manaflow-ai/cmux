internal import Darwin
internal import Foundation
internal import os

/// Why the server could not admit an accepted connection to a command job.
public enum ControlOverloadReason: String, Sendable, Equatable {
    /// The connection pool had no live slot and no pending slot left.
    case poolSaturated = "pool_saturated"
    /// The connection waited in the pending queue longer than a client waits
    /// for a reply, so running its command late would only produce stale
    /// side effects.
    case pendingExpired = "pending_expired"
    /// Too many unauthenticated peers were already being read.
    case preauthorizationSaturated = "preauthorization_saturated"
    /// The pool is stopping (application termination or a listener restart).
    case serverStopping = "server_stopping"
    /// The accepted-connection buffer between the listener and the pool was
    /// full because the consumer fell behind.
    case acceptBufferFull = "accept_buffer_full"
}

/// One rejection handled by ``ControlOverloadResponder``, reported to the host.
public struct ControlOverloadRejection: Sendable, Equatable {
    /// Why the connection was rejected.
    public let reason: ControlOverloadReason
    /// Whether a structured error reply reached the client before the close.
    public let replied: Bool
    /// Rejections still being answered when this one finished.
    public let activeReplies: Int

    /// Creates a rejection report.
    public init(reason: ControlOverloadReason, replied: Bool, activeReplies: Int) {
        self.reason = reason
        self.replied = replied
        self.activeReplies = activeReplies
    }
}

/// Answers connections the server cannot serve with a real error instead of
/// closing their descriptor.
///
/// Closing a freshly accepted descriptor is what every client experienced
/// as `Failed to write to socket (Broken pipe, errno 32)` in
/// <https://github.com/manaflow-ai/cmux/issues/13369>. The responder instead
/// reads the client's first request line within a short bounded window (so
/// the client's write has landed and the reply can echo its request `id`),
/// writes an `overloaded` error that carries `retryable`, `retry_after_ms`
/// and the rejection reason, and only then shuts the connection down. The
/// request is never authenticated or executed; the line is parsed only for
/// its envelope `id`.
///
/// At most `maximumConcurrentReplies` rejections are answered at once; past
/// that the descriptor is closed immediately, which bounds the resources a
/// rejection flood can hold. Size it above everything the pool can reject in
/// one burst (its live plus pending capacity, and the preauthorization
/// claims), or a batch expiry would push concurrent rejections back to a bare
/// close. Each reply runs on its own detached task
/// because rejection happens inside the pool's synchronous drop callback.
public final class ControlOverloadResponder: Sendable {
    /// Host-localized copy for the error reply.
    public struct Strings: Sendable {
        /// The human-readable `overloaded` error message.
        public let message: String

        /// Creates the copy set.
        public init(message: String) {
            self.message = message
        }
    }

    /// Tunables for the reply path.
    public struct Configuration: Sendable {
        /// Rejections answered concurrently before falling back to a bare close.
        public let maximumConcurrentReplies: Int
        /// How long to wait for the client's first line before closing.
        public let readDeadlineMilliseconds: Int
        /// Bytes accepted from an unserved client while looking for its line.
        public let maximumRequestBytes: Int
        /// The `retry_after_ms` hint written into the reply.
        public let retryAfterMilliseconds: Int

        /// Creates a configuration.
        ///
        /// - Parameters:
        ///   - maximumConcurrentReplies: Concurrent reply bound (default 256).
        ///   - readDeadlineMilliseconds: First-line wait (default 2 s).
        ///   - maximumRequestBytes: First-line byte cap (default 64 KiB).
        ///   - retryAfterMilliseconds: Retry hint (default 500 ms).
        public init(
            maximumConcurrentReplies: Int = 256,
            readDeadlineMilliseconds: Int = 2_000,
            maximumRequestBytes: Int = 64 * 1024,
            retryAfterMilliseconds: Int = 500
        ) {
            self.maximumConcurrentReplies = max(0, maximumConcurrentReplies)
            self.readDeadlineMilliseconds = max(1, readDeadlineMilliseconds)
            self.maximumRequestBytes = max(1, maximumRequestBytes)
            self.retryAfterMilliseconds = max(0, retryAfterMilliseconds)
        }
    }

    /// Point-in-time counters.
    public struct Metrics: Sendable, Equatable {
        /// Rejections currently being answered.
        public let activeReplies: Int
        /// Rejections that reached the client with a structured error.
        public let repliedConnections: Int
        /// Rejections closed without a reply (bound reached, silent peer, or write failure).
        public let closedWithoutReply: Int

        /// Creates a metrics snapshot.
        public init(activeReplies: Int, repliedConnections: Int, closedWithoutReply: Int) {
            self.activeReplies = activeReplies
            self.repliedConnections = repliedConnections
            self.closedWithoutReply = closedWithoutReply
        }
    }

    private struct State: Sendable {
        var activeReplies = 0
        var repliedConnections = 0
        var closedWithoutReply = 0
        var stopped = false
        var nextRejectionID: UInt64 = 1
        var tasks: [UInt64: Task<Void, Never>] = [:]
        /// Replies that finished before ``reject(socket:reason:)`` registered
        /// their task; registration then skips them instead of leaking a
        /// completed handle.
        var finishedBeforeRegistration: Set<UInt64> = []
    }

    /// The `overloaded` wire error code.
    public static let errorCode = "overloaded"

    private let strings: Strings
    private let configuration: Configuration
    private let onRejection: @Sendable (ControlOverloadRejection) -> Void
    // Lock carve-out: `reject(socket:reason:)` is called from the pool's
    // synchronous drop callback and must admit-or-close without an async hop;
    // the critical sections only touch counters and the task table.
    private let state: OSAllocatedUnfairLock<State>
    private let parser = ControlRequestParser()
    private let encoder = ControlResponseEncoder()

    /// Creates a responder.
    ///
    /// - Parameters:
    ///   - strings: Host-localized reply copy.
    ///   - configuration: Reply-path tunables.
    ///   - onRejection: Telemetry sink invoked once per finished rejection,
    ///     from the reply task.
    public init(
        strings: Strings,
        configuration: Configuration = Configuration(),
        onRejection: @escaping @Sendable (ControlOverloadRejection) -> Void = { _ in }
    ) {
        self.strings = strings
        self.configuration = configuration
        self.onRejection = onRejection
        self.state = OSAllocatedUnfairLock(initialState: State())
    }

    /// Takes ownership of `socket`, answers it with an `overloaded` error when
    /// a reply slot is free, and closes it.
    ///
    /// - Parameters:
    ///   - socket: The accepted descriptor the server cannot serve.
    ///   - reason: Why the connection was rejected.
    public func reject(socket: Int32, reason: ControlOverloadReason) {
        let admission = state.withLock { state -> (admitted: Bool, id: UInt64, activeReplies: Int) in
            guard !state.stopped, state.activeReplies < configuration.maximumConcurrentReplies else {
                state.closedWithoutReply += 1
                return (false, 0, state.activeReplies)
            }
            state.activeReplies += 1
            let id = state.nextRejectionID
            state.nextRejectionID &+= 1
            return (true, id, state.activeReplies)
        }
        guard admission.admitted else {
            close(socket)
            onRejection(ControlOverloadRejection(reason: reason, replied: false, activeReplies: admission.activeReplies))
            return
        }
        let rejectionID = admission.id
        // Detached on purpose: the caller is the pool's synchronous drop
        // callback, and the reply must not inherit any actor context.
        let task = Task.detached(priority: .utility) { [self] in
            let replied = await self.reply(socket: socket, reason: reason)
            let activeReplies = self.state.withLock { state -> Int in
                state.activeReplies -= 1
                if state.tasks.removeValue(forKey: rejectionID) == nil {
                    state.finishedBeforeRegistration.insert(rejectionID)
                }
                if replied {
                    state.repliedConnections += 1
                } else {
                    state.closedWithoutReply += 1
                }
                return state.activeReplies
            }
            self.onRejection(ControlOverloadRejection(reason: reason, replied: replied, activeReplies: activeReplies))
        }
        state.withLock { state in
            if state.finishedBeforeRegistration.remove(rejectionID) == nil {
                state.tasks[rejectionID] = task
            }
        }
    }

    /// Returns current counters.
    public func metrics() -> Metrics {
        state.withLock { state in
            Metrics(
                activeReplies: state.activeReplies,
                repliedConnections: state.repliedConnections,
                closedWithoutReply: state.closedWithoutReply
            )
        }
    }

    /// Stops answering; in-flight replies are cancelled and later rejections
    /// close immediately.
    public func stop() {
        let tasks = state.withLock { state -> [Task<Void, Never>] in
            state.stopped = true
            return Array(state.tasks.values)
        }
        for task in tasks {
            task.cancel()
        }
    }

    /// The reply for one request line: a v2 error echoing the envelope `id`
    /// when the line is a JSON request, or the v1 `ERROR:` form otherwise.
    func response(forRequestLine line: String, reason: ControlOverloadReason) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{") else {
            return "ERROR: \(Self.errorCode) retry_after_ms=\(configuration.retryAfterMilliseconds) reason=\(reason.rawValue)"
        }
        return encoder.error(
            id: parser.lenientRequest(fromLine: trimmed)?.id,
            code: Self.errorCode,
            message: strings.message,
            data: .object([
                "retryable": .bool(true),
                "retry_after_ms": .int(Int64(configuration.retryAfterMilliseconds)),
                "reason": .string(reason.rawValue),
            ])
        )
    }

    private func reply(socket: Int32, reason: ControlOverloadReason) async -> Bool {
        let reader = ControlClientAsyncLineReader(
            socket: socket,
            initialLimits: ControlClientLineReadLimits(
                maximumBytes: configuration.maximumRequestBytes,
                timeoutMilliseconds: configuration.readDeadlineMilliseconds
            )
        )
        let writer = ControlClientAsyncWriter(socket: socket)
        var replied = false
        if let line = await reader.nextLine(shouldContinueReading: { true }) {
            let response = self.response(forRequestLine: line, reason: reason)
            replied = await writer.writeAll(Data((response + "\n").utf8))
        }
        await reader.cancelAndWait()
        await writer.cancelAndWait()
        shutdown(socket, SHUT_RDWR)
        close(socket)
        return replied
    }
}

import Foundation

/// Handle to an active output subscription (D22 — class, not protocol).
///
/// Phase 2 constructs one per HTTP SSE client and pumps events into the
/// per-subscriber ring. Phase 0 ships the type so downstream code only
/// USES it.
///
/// - `cancel()` releases the per-subscriber ring and fires `onCancel`
///   exactly once; idempotent.
/// - `signalEnd()` fires `onEnd` exactly once (for example, when the
///   surface closes) and finishes the async stream. Does not invoke
///   `onCancel`.
/// - `events()` returns an `AsyncStream<OutputEvent>` that delivers
///   every prior buffered yield, then live yields until `cancel()` or
///   `signalEnd()` finishes the stream.
///
/// The type is marked `@unchecked Sendable` because it carries a
/// publicly mutable `onEnd` closure and lock-protected state. All
/// mutable state is serialized behind an internal `NSLock`.
public final class OutputSubscription: @unchecked Sendable {
    /// Stable per-subscriber identifier; used by the audit log.
    public let id: UUID
    /// Surface this subscription is attached to.
    public let handle: SurfaceHandle
    /// Stream mode selected at subscription time.
    public let mode: StreamMode

    private let lock = NSLock()
    private var cancelled: Bool = false
    private var ended: Bool = false
    private let onCancel: @Sendable () -> Void

    /// Hook fired exactly once by ``signalEnd()``. Set by the Phase 2
    /// service to drive end-of-stream cleanup. Reads and writes are
    /// serialized internally.
    public var onEnd: (@Sendable () -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _onEnd }
        set { lock.lock(); _onEnd = newValue; lock.unlock() }
    }
    private var _onEnd: (@Sendable () -> Void)?

    /// The async-stream continuation is lazily attached on first
    /// ``events()`` call. Yields from ``yield(_:)`` are buffered until
    /// then so a producer that runs ahead of the consumer does not
    /// drop events.
    private var continuation: AsyncStream<OutputEvent>.Continuation?
    private var buffered: [OutputEvent] = []

    /// Creates a subscription handle.
    ///
    /// - Parameters:
    ///   - id: Stable identifier.
    ///   - handle: Target surface.
    ///   - mode: ``StreamMode/raw`` or ``StreamMode/cells``.
    ///   - onCancel: Invoked exactly once when ``cancel()`` is called
    ///     (directly or via async-stream termination).
    public init(
        id: UUID,
        handle: SurfaceHandle,
        mode: StreamMode,
        onCancel: @escaping @Sendable () -> Void
    ) {
        self.id = id
        self.handle = handle
        self.mode = mode
        self.onCancel = onCancel
    }

    /// Returns the async stream of events.
    ///
    /// Calling this more than once is undefined — Phase 2 attaches one
    /// consumer per subscription. Pre-``events()`` yields are buffered
    /// and replayed at the head of the stream.
    public func events() -> AsyncStream<OutputEvent> {
        AsyncStream { continuation in
            lock.lock()
            self.continuation = continuation
            let pending = self.buffered
            self.buffered.removeAll(keepingCapacity: false)
            let alreadyFinished = self.ended || self.cancelled
            lock.unlock()
            for ev in pending { continuation.yield(ev) }
            if alreadyFinished {
                continuation.finish()
                return
            }
            continuation.onTermination = { [weak self] _ in self?.cancel() }
        }
    }

    /// Pushes one event onto the stream. Called by the Phase 2 service.
    /// No-op after ``cancel()`` or ``signalEnd()``.
    public func yield(_ event: OutputEvent) {
        lock.lock()
        if cancelled || ended {
            lock.unlock()
            return
        }
        if let cont = continuation {
            lock.unlock()
            cont.yield(event)
            return
        }
        buffered.append(event)
        lock.unlock()
    }

    /// Finishes the async stream without firing `onEnd` or `onCancel`.
    /// Used by the service when the subscriber explicitly disconnects.
    public func finish() {
        lock.lock()
        if ended || cancelled {
            lock.unlock()
            return
        }
        ended = true
        let cont = continuation
        continuation = nil
        lock.unlock()
        cont?.finish()
    }

    /// Cancels the subscription. Idempotent; fires `onCancel` exactly
    /// once.
    public func cancel() {
        lock.lock()
        if cancelled {
            lock.unlock()
            return
        }
        cancelled = true
        let cont = continuation
        continuation = nil
        lock.unlock()
        cont?.finish()
        onCancel()
    }

    /// Signals end-of-stream (for example, the surface closed). Fires
    /// `onEnd` exactly once and finishes the async stream. Does not
    /// call `onCancel`.
    public func signalEnd() {
        lock.lock()
        if ended || cancelled {
            lock.unlock()
            return
        }
        ended = true
        let cont = continuation
        continuation = nil
        let hook = _onEnd
        _onEnd = nil
        lock.unlock()
        cont?.finish()
        hook?()
    }
}

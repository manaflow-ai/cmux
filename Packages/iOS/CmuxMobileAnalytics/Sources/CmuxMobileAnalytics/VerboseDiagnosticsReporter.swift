public import CMUXMobileCore
public import Foundation
internal import OSLog
internal import os

private let verboseDiagnosticsOSLog = Logger(
    subsystem: "dev.cmux.ios",
    category: "verbose-diagnostics"
)

/// One diagnostic event resolved for upload: the ring's privacy-safe integer
/// payload plus the wall-clock timestamp and server-readable text rendered
/// from it. Contains nothing the ``CMUXMobileCore/DiagnosticEvent`` schema
/// does not already bound: no terminal contents, credentials, peer
/// identities, or free-form errors.
public struct VerboseDiagnosticsEntry: Sendable, Equatable {
    /// The event's wall-clock time, mapped through the reporter's anchor.
    public let at: Date
    /// The stable numeric event code (``CMUXMobileCore/DiagnosticEventCode``).
    public let code: Int
    /// The stable machine name of the event code.
    public let name: String
    /// The plain-language event summary, rendered with a fixed POSIX locale
    /// so server-side text is stable across device languages.
    public let summary: String
    public let surface: UInt32?
    public let ms: UInt32?
    public let a: Int?
    public let b: Int?
    public let c: Int?

    public init(
        at: Date,
        code: Int,
        name: String,
        summary: String,
        surface: UInt32? = nil,
        ms: UInt32? = nil,
        a: Int? = nil,
        b: Int? = nil,
        c: Int? = nil
    ) {
        self.at = at
        self.code = code
        self.name = name
        self.summary = summary
        self.surface = surface
        self.ms = ms
        self.a = a
        self.b = b
        self.c = c
    }
}

/// One upload batch handed to the ``VerboseDiagnosticsUploading`` seam.
public struct VerboseDiagnosticsBatch: Sendable, Equatable {
    public let entries: [VerboseDiagnosticsEntry]
    /// Signed-bundle build identity, sanitized upstream.
    public let buildStamp: String
    /// The per-install anonymous analytics id, so server logs can separate
    /// two devices on the same account. Never a hardware identifier.
    public let clientID: String?

    public init(entries: [VerboseDiagnosticsEntry], buildStamp: String, clientID: String?) {
        self.entries = entries
        self.buildStamp = buildStamp
        self.clientID = clientID
    }
}

/// Network seam for verbose diagnostics uploads, mirroring
/// ``AnalyticsUploading``'s result semantics so the reporter and its tests
/// reuse ``AnalyticsUploadResult``.
public protocol VerboseDiagnosticsUploading: Sendable {
    func upload(_ batch: VerboseDiagnosticsBatch) async -> AnalyticsUploadResult
}

/// Streams the app's structured diagnostic events to the cmux backend for
/// accounts the server has flagged with `cmuxVerboseDiagnostics: true`.
///
/// Constructed once at the app composition root and fanned into the
/// ``CMUXMobileCore/DiagnosticLog`` event tap alongside the existing file and
/// Sentry consumers. The design contract, in order of importance:
///
/// - **Zero overhead when the flag is absent.** ``ingest(_:)`` is
///   `nonisolated`, synchronous, and returns after a single lock-protected
///   boolean read while the account is not flagged. Nothing is buffered, no
///   task is spawned, no timer runs (the flush cadence starts lazily on the
///   first accepted event).
/// - **Never blocks UI or connection paths.** Accepted events are yielded
///   onto an internal `AsyncStream`; a single consumer task batches and
///   uploads off every caller path, exactly like ``AnalyticsEmitter``.
/// - **Resilient to backend failure by dropping.** A batch is removed from
///   the buffer before its upload is attempted; on any non-2xx outcome or
///   transport error it is simply gone, an outage gate suppresses per-event
///   drains, and only the periodic cadence retries with *fresh* events, so
///   a 429 or outage can never crash the app, block it, or grow an unbounded
///   queue (the buffer itself is also hard-capped, dropping oldest).
/// - **The client flag is a mirror, not an authority.** The backend
///   re-checks the server-written account flag on every upload and rejects
///   unflagged accounts, so a stale or tampered client cannot opt itself in.
public actor VerboseDiagnosticsReporter {
    private enum Item: Sendable {
        case event(DiagnosticEvent)
        case authorization(Bool)
        case barrier(UUID)
    }

    private let uploader: any VerboseDiagnosticsUploading
    private let clock: any Clock<Duration>
    private let buildStamp: String
    private let clientID: String?
    private let flushBatchSize: Int
    private let flushInterval: Duration
    private let maxPendingEvents: Int
    private let anchorWallNanos: UInt64
    private let anchorMonotonicNanos: UInt64
    /// Fixed-locale presenter so uploaded text is stable for server-side
    /// reading regardless of the device language.
    private let presentation = DiagnosticEventPresentation(
        locale: Locale(identifier: "en_US_POSIX")
    )

    // lint:allow lock - `ingest` runs on the diagnostic ring's drain task and
    // must stay synchronous and non-blocking; the critical region reads or
    // writes one boolean.
    private let authorizationGate = OSAllocatedUnfairLock(initialState: false)

    private let stream: AsyncStream<Item>
    private let continuation: AsyncStream<Item>.Continuation

    private var pending: [DiagnosticEvent] = []
    private var barriers: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var consumerTask: Task<Void, Never>?
    private var cadenceTask: Task<Void, Never>?
    /// Consumer-side mirror of the authorization gate, updated in stream
    /// order so events raced past a disable are still dropped.
    private var isAuthorized = false
    /// Whether the last upload attempt failed. While open, per-event drains
    /// are suppressed and only the cadence barrier attempts again (with new
    /// events), bounding failed POSTs to one per ``flushInterval``.
    private var uploadOutageOpen = false

    /// Creates a reporter and begins consuming accepted events.
    ///
    /// - Parameters:
    ///   - uploader: The network seam that ships batches.
    ///   - buildStamp: Short signed-bundle build identity for the upload.
    ///   - clientID: The per-install anonymous analytics id, if available.
    ///   - clock: Drives the flush cadence; inject a test clock for virtual
    ///     time. The cadence is an intentional bounded batching delay, not a
    ///     synchronization substitute, and it is cancelled with the reporter.
    ///   - flushBatchSize: Drain when this many events are buffered. Default 40.
    ///   - flushInterval: The periodic flush cadence. Default 5s.
    ///   - maxPendingEvents: Hard cap on the buffered backlog (drop-oldest).
    ///     Default 512.
    ///   - anchorWallNanos: Wall-clock time at construction (nanoseconds since
    ///     the Unix epoch), paired with `anchorMonotonicNanos` to map each
    ///     event's monotonic timestamp to absolute time. Injected for tests.
    ///   - anchorMonotonicNanos: The monotonic reading captured at the same
    ///     instant. Injected for tests.
    public init(
        uploader: any VerboseDiagnosticsUploading,
        buildStamp: String,
        clientID: String? = nil,
        clock: any Clock<Duration> = ContinuousClock(),
        flushBatchSize: Int = 40,
        flushInterval: Duration = .seconds(5),
        maxPendingEvents: Int = 512,
        anchorWallNanos: UInt64 = UInt64(max(0, Date().timeIntervalSince1970 * 1_000_000_000)),
        anchorMonotonicNanos: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) {
        self.uploader = uploader
        self.buildStamp = buildStamp
        self.clientID = clientID
        self.clock = clock
        self.flushBatchSize = max(1, flushBatchSize)
        self.flushInterval = flushInterval
        self.maxPendingEvents = max(self.flushBatchSize, maxPendingEvents)
        self.anchorWallNanos = anchorWallNanos
        self.anchorMonotonicNanos = anchorMonotonicNanos
        // Unbounded like `AnalyticsEmitter`'s channel: `flush()` barriers ride
        // the same stream, and a bounded policy could evict a barrier under a
        // burst and hang the flush. The steady-state backlog is still bounded
        // by `maxPendingEvents` (drop-oldest) on the consumer side, and the
        // stream stays empty for every unflagged account because `ingest`
        // never yields.
        let (stream, continuation) = AsyncStream<Item>.makeStream(
            bufferingPolicy: .unbounded
        )
        self.stream = stream
        self.continuation = continuation
        Task { await self.startConsuming() }
    }

    // MARK: Non-blocking surface

    /// Accepts one diagnostic event from the ring's event tap.
    ///
    /// Hot-path contract: while the account is not flagged this is a single
    /// synchronized boolean read and an immediate return. While flagged it is
    /// one bounded-stream yield; batching, rendering, and networking all
    /// happen on the consumer task.
    public nonisolated func ingest(_ event: DiagnosticEvent) {
        guard authorizationGate.withLock({ $0 }) else { return }
        continuation.yield(.event(event))
    }

    /// Updates the account authorization mirror (the server-written
    /// `cmuxVerboseDiagnostics` flag on the signed-in user).
    ///
    /// Turning authorization off also discards everything buffered but not
    /// yet uploaded, so a sign-out or server-side flag removal stops
    /// deliveries at the next consumer step.
    public nonisolated func setAuthorization(enabled: Bool) {
        let changed = authorizationGate.withLock { state -> Bool in
            guard state != enabled else { return false }
            state = enabled
            return true
        }
        guard changed else { return }
        continuation.yield(.authorization(enabled))
    }

    /// Drains every event accepted before this call (FIFO barrier), waiting
    /// for the resulting upload attempt to finish. Used by tests and by the
    /// app's background transition; like all drains it never retries.
    public func flush() async {
        let id = UUID()
        await withCheckedContinuation { (resume: CheckedContinuation<Void, Never>) in
            barriers[id] = resume
            continuation.yield(.barrier(id))
        }
    }

    // MARK: Actor-isolated consumer

    private func startConsuming() {
        guard consumerTask == nil else { return }
        consumerTask = Task { [weak self] in
            guard let self else { return }
            await self.consume()
        }
    }

    private func consume() async {
        for await item in stream {
            switch item {
            case let .event(event):
                guard isAuthorized else { continue }
                pending.append(event)
                if pending.count > maxPendingEvents {
                    pending.removeFirst(pending.count - maxPendingEvents)
                }
                startCadenceIfNeeded()
                if pending.count >= flushBatchSize && !uploadOutageOpen {
                    await drain()
                }
            case let .authorization(enabled):
                isAuthorized = enabled
                if !enabled {
                    pending.removeAll()
                    uploadOutageOpen = false
                }
            case let .barrier(id):
                await drain()
                barriers.removeValue(forKey: id)?.resume()
            }
        }
    }

    private func startCadenceIfNeeded() {
        guard cadenceTask == nil else { return }
        cadenceTask = Task { [weak self, flushInterval, clock] in
            while !Task.isCancelled {
                // Bounded periodic batching delay via the injected clock
                // (cancellable, virtual-time testable). This is the intended
                // upload cadence, not a synchronization substitute.
                try? await clock.sleep(for: flushInterval)
                guard let self, !Task.isCancelled else { return }
                await self.requestCadenceFlush()
            }
        }
    }

    private func requestCadenceFlush() {
        // An unregistered barrier id drains without resuming anything.
        continuation.yield(.barrier(UUID()))
    }

    private func drain() async {
        guard !pending.isEmpty else { return }
        // Remove the batch before attempting the upload: whatever the
        // outcome, these events are never retried and can never accumulate.
        let batch = pending
        pending.removeAll()
        let payload = VerboseDiagnosticsBatch(
            entries: batch.map(resolvedEntry),
            buildStamp: buildStamp,
            clientID: clientID
        )
        switch await uploader.upload(payload) {
        case .accepted:
            uploadOutageOpen = false
        case .drop, .retry:
            // Backend outage, backpressure (429), or rejection (an unflagged
            // account hitting the server's double gate). Drop the batch and
            // fall back to cadence-only attempts so failures cost at most one
            // POST per flush interval.
            uploadOutageOpen = true
            verboseDiagnosticsOSLog.debug(
                "verbose diagnostics batch dropped count=\(batch.count, privacy: .public)"
            )
        }
    }

    private func resolvedEntry(_ event: DiagnosticEvent) -> VerboseDiagnosticsEntry {
        VerboseDiagnosticsEntry(
            at: wallDate(forMonotonicNanos: event.tNanos),
            code: Int(event.code.rawValue),
            name: presentation.name(event.code),
            summary: presentation.summary(event),
            surface: event.surface,
            ms: event.ms,
            a: event.a,
            b: event.b,
            c: event.c
        )
    }

    private func wallDate(forMonotonicNanos nanos: UInt64) -> Date {
        let deltaNanos: Double = nanos >= anchorMonotonicNanos
            ? Double(nanos - anchorMonotonicNanos)
            : -Double(anchorMonotonicNanos - nanos)
        let wallSeconds = Double(anchorWallNanos) / 1_000_000_000
        return Date(timeIntervalSince1970: wallSeconds + deltaNanos / 1_000_000_000)
    }

    deinit {
        continuation.finish()
        consumerTask?.cancel()
        cadenceTask?.cancel()
        for (_, resume) in barriers { resume.resume() }
    }
}

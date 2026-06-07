public import CMUXMobileCore
public import Foundation
internal import OSLog

private let analyticsLog = Logger(subsystem: "dev.cmux.ios", category: "analytics")

/// The de-singletonized, non-blocking product-analytics emitter.
///
/// Constructed once at the app composition root and injected everywhere as `any
/// AnalyticsEmitting`. It buffers events off-main, merges super-properties and
/// the current identity onto each event in submission order, and flushes a batch
/// to the injected ``AnalyticsUploading`` when the buffer fills, on a cadence
/// driven by an injected `Clock`, or when the caller forces a ``flush()`` (the
/// app does this on background so events survive suspension).
///
/// ### Why an AsyncStream channel, and how it stays off the hot path
///
/// ``capture(_:_:)`` is a `nonisolated`, synchronous, non-throwing method whose
/// only work is a synchronous `continuation.yield(...)` onto an internal
/// `AsyncStream` — an `O(1)` enqueue, no `Task` spawn, no actor hop, no
/// allocation per event. A single consumer task drains the stream on the actor,
/// so event order, identity changes, and super-property updates are applied in
/// submission order. The one blocking network call lives inside the consumer's
/// `drain`, off every UI and input path. The terminal-input and render
/// fire-sites therefore call `analytics.capture(...)` with no `await`.
///
/// ### Privacy gate
///
/// ``capture(_:_:)`` consults the injected ``AnalyticsConsentProviding`` *before*
/// yielding, so when telemetry is disabled nothing is even buffered, and no
/// fire-site can bypass the opt-out. `identify` and super-property updates are
/// gated the same way.
///
/// ### Flush barrier
///
/// ``flush()`` pushes a barrier sentinel through the same FIFO and suspends until
/// the consumer reaches it, having drained everything submitted before it. That
/// makes flush deterministic (no sleeps) and lets tests assert exact upload
/// contents.
public actor AnalyticsEmitter: AnalyticsEmitting {
    private enum Item: Sendable {
        case event(name: String, properties: [String: AnalyticsValue], timestamp: Date)
        case identify(userID: String?, alias: String?, properties: [String: AnalyticsValue])
        case superProperties([String: AnalyticsValue])
        case barrier(UUID)
    }

    private let uploader: any AnalyticsUploading
    private let consent: any AnalyticsConsentProviding
    private let clock: any Clock<Duration>
    private let now: @Sendable () -> Date
    private let anonymousID: String
    private let flushBatchSize: Int
    private let flushInterval: Duration

    private let stream: AsyncStream<Item>
    private let continuation: AsyncStream<Item>.Continuation

    private var superProperties: [String: AnalyticsValue] = [:]
    private var distinctID: String?
    private var pending: [AnalyticsEvent] = []
    private var barriers: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var consumerTask: Task<Void, Never>?
    private var cadenceTask: Task<Void, Never>?

    /// Creates an emitter and begins consuming submitted events.
    ///
    /// - Parameters:
    ///   - uploader: The network seam that ships batches.
    ///   - consent: The opt-out gate, read before every capture/identify.
    ///   - anonymousID: The stable per-install client id used as the pre-auth
    ///     distinct id (from `MobileClientIDRepository`).
    ///   - clock: The clock driving the flush cadence. Inject a test clock to
    ///     advance virtual time deterministically.
    ///   - now: Supplies the current wall-clock time stamped onto each event at
    ///     submission so timestamps stay ordered.
    ///   - flushBatchSize: Flush when this many events are buffered. Default 50.
    ///   - flushInterval: The periodic flush cadence. Default 30s.
    public init(
        uploader: any AnalyticsUploading,
        consent: any AnalyticsConsentProviding,
        anonymousID: String,
        clock: any Clock<Duration> = ContinuousClock(),
        now: @escaping @Sendable () -> Date = { Date() },
        flushBatchSize: Int = 50,
        flushInterval: Duration = .seconds(30)
    ) {
        self.uploader = uploader
        self.consent = consent
        self.anonymousID = anonymousID
        self.clock = clock
        self.now = now
        self.flushBatchSize = flushBatchSize
        self.flushInterval = flushInterval
        self.distinctID = anonymousID
        (self.stream, self.continuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
        Task { await self.startConsuming() }
    }

    // MARK: AnalyticsEmitting (non-blocking surface)

    public nonisolated func capture(_ event: String, _ properties: [String: AnalyticsValue]) {
        guard consent.isTelemetryEnabled else { return }
        continuation.yield(.event(name: event, properties: properties, timestamp: now()))
    }

    public nonisolated func identify(
        userId: String?,
        alias: String?,
        properties: [String: AnalyticsValue]
    ) {
        guard consent.isTelemetryEnabled else { return }
        continuation.yield(.identify(userID: userId, alias: alias, properties: properties))
    }

    public nonisolated func setSuperProperties(_ properties: [String: AnalyticsValue]) {
        guard consent.isTelemetryEnabled else { return }
        continuation.yield(.superProperties(properties))
    }

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
            case let .event(name, properties, timestamp):
                appendEvent(name: name, properties: properties, timestamp: timestamp)
                startCadenceIfNeeded()
                if pending.count >= flushBatchSize {
                    await drain()
                }
            case let .identify(userID, alias, properties):
                await applyIdentify(userID: userID, alias: alias, properties: properties)
            case let .superProperties(properties):
                for (key, value) in properties { superProperties[key] = value }
            case let .barrier(id):
                await drain()
                barriers.removeValue(forKey: id)?.resume()
            }
        }
    }

    private func appendEvent(name: String, properties: [String: AnalyticsValue], timestamp: Date) {
        var merged = superProperties
        for (key, value) in properties { merged[key] = value }
        pending.append(
            AnalyticsEvent(
                name: name,
                properties: merged,
                distinctID: distinctID,
                anonymousID: anonymousID == distinctID ? nil : anonymousID,
                timestamp: timestamp
            )
        )
    }

    private func applyIdentify(
        userID: String?,
        alias: String?,
        properties: [String: AnalyticsValue]
    ) async {
        distinctID = userID ?? anonymousID
        if let userID {
            superProperties["user_id"] = .string(userID)
        } else {
            superProperties.removeValue(forKey: "user_id")
        }
        var personProps: [String: any Sendable] = [:]
        for (key, value) in properties { personProps[key] = value.jsonObject }
        let aliasID = alias ?? (anonymousID == userID ? nil : anonymousID)
        let result = await uploader.identify(
            userID: userID,
            anonymousID: aliasID,
            properties: personProps
        )
        if result == .retry {
            analyticsLog.debug("identify deferred (transient)")
        }
    }

    private func startCadenceIfNeeded() {
        guard cadenceTask == nil else { return }
        cadenceTask = Task { [weak self, flushInterval, clock] in
            while !Task.isCancelled {
                // Bounded periodic delay via the injected clock (cancellable,
                // virtual-time testable). Not used to poll/settle — it is the
                // intended flush cadence; the barrier it yields drains the buffer.
                try? await clock.sleep(for: flushInterval)
                guard let self, !Task.isCancelled else { return }
                await self.requestCadenceFlush()
            }
        }
    }

    private func requestCadenceFlush() {
        // A barrier id that is not registered in `barriers` flushes without
        // resuming anything (the consumer's `barriers.removeValue` no-ops).
        continuation.yield(.barrier(UUID()))
    }

    private func drain() async {
        while !pending.isEmpty {
            let batch = pending
            let result = await uploader.upload(batch)
            switch result {
            case .accepted, .drop:
                // Remove exactly the events we attempted; events appended during
                // the await stay queued for the next pass.
                pending.removeFirst(min(batch.count, pending.count))
            case .retry:
                // Leave the buffer intact; the cadence barrier or the next flush
                // retries. Stop draining now to avoid a tight failure loop.
                return
            }
        }
    }

    deinit {
        continuation.finish()
        consumerTask?.cancel()
        cadenceTask?.cancel()
        for (_, resume) in barriers { resume.resume() }
    }
}

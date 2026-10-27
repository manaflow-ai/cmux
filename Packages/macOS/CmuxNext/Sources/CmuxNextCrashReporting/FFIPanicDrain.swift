public import Sentry

/// One panic an in-app Rust export caught in its FFI boundary: a `CmuxFfiPanic` record of
/// cmux-ffi-guard's fixed ring, read with `cmux_ffi_take_panic`.
public struct FFIPanicRecord: Sendable, Equatable {
    /// 1 for the process's first guarded panic, then one more per panic; a gap counts the panics
    /// the ring lost.
    public var sequence: UInt64
    /// The export whose body panicked, such as `cmux_rd_session_open`.
    public var export: String
    /// The panic message, cut at the ring's message cap.
    public var message: String
    /// Whether the message was cut.
    public var truncated: Bool

    /// - Parameters:
    ///   - sequence: The record's sequence number.
    ///   - export: The export whose body panicked.
    ///   - message: The panic message.
    ///   - truncated: Whether the message was cut.
    public init(sequence: UInt64, export: String, message: String, truncated: Bool) {
        self.sequence = sequence
        self.export = export
        self.message = message
        self.truncated = truncated
    }
}

/// Sends the panics cmux-ffi-guard caught in in-app Rust exports to Sentry (p10-stability-150).
///
/// The guard keeps each caught panic in a preallocated ring and the export returns its error
/// value, so the app keeps running; the ring is read later, as Chrome's crash keys are
/// (components/crash/core/common/crash_key.h). ``drain()`` takes every stored record through the
/// injected `take` (`cmux_ffi_take_panic` in the app) and sends each, scrubbed of paths, when the
/// person allows reports; with reports off the records are taken and dropped. A value type: its
/// owner calls it from one queue.
public struct FFIPanicDrain: Sendable {
    /// Records one drain takes at most: the ring's slot count (cmux-ffi-guard `RING_SLOTS`).
    public static let maxPerDrain = 16

    private let take: @Sendable () -> FFIPanicRecord?
    private let sends: Bool
    private let capture: @Sendable (Event) -> Void
    /// The sequence of the last record taken; the next record's gap from it is the panics lost.
    private var lastSequence: UInt64 = 0

    /// - Parameters:
    ///   - sends: The person's telemetry choice; false takes records without sending them.
    ///   - take: The ring's oldest record, removed from it; nil when the ring is empty.
    ///   - capture: Sends one event (Sentry in the app, a recorder in tests).
    public init(sends: Bool, take: @escaping @Sendable () -> FFIPanicRecord?,
                capture: @escaping @Sendable (Event) -> Void = { SentrySDK.capture(event: $0, scope: Scope()) }) {
        self.sends = sends
        self.take = take
        self.capture = capture
    }

    /// Takes the stored records and sends each; returns the events sent.
    @discardableResult
    public mutating func drain() -> [Event] {
        var sent: [Event] = []
        for _ in 0..<Self.maxPerDrain {
            guard let record = take() else { break }
            let gap = record.sequence > lastSequence ? record.sequence - lastSequence : 0
            let lost = gap > 1 ? gap - 1 : 0
            lastSequence = record.sequence
            guard sends else { continue }
            let event = Self.event(for: record, lostBefore: lost)
            capture(event)
            sent.append(event)
        }
        return sent
    }

    /// The Sentry event for one caught panic: handled (the export returned its error value),
    /// grouped by export.
    static func event(for record: FFIPanicRecord, lostBefore: UInt64) -> Event {
        let source = RustPanicSource.ffiBoundary
        let message = RustLogScrubber().scrub(record.message)
        let event = Event(level: .error)
        let exception = Exception(value: message, type: "RustPanic")
        let mechanism = Mechanism(type: "rust_ffi_panic")
        mechanism.handled = true
        exception.mechanism = mechanism
        event.exceptions = [exception]
        event.message = SentryMessage(formatted: "\(source.label) in \(record.export): \(message)")
        event.fingerprint = [source.fingerprintPrefix, record.export]
        event.tags = ["process": source.process, "crash_source": source.crashSource, "ffi_export": record.export]
        event.extra = ["sequence": record.sequence, "truncated": record.truncated, "lost_before": lostBefore]
        return event
    }
}

import Foundation

/// One structured diagnostic event recorded on a hot path.
///
/// The value is deliberately tiny and free of any allocated string: a
/// ``DiagnosticEventCode``, a monotonic ``tNanos`` timestamp, and a handful of
/// optional integer fields. Recording one is a struct copy onto an
/// `AsyncStream` continuation with no formatting work, so it is cheap enough for
/// the input and render seams that the string-based ``MobileDebugLog`` is too
/// heavy for. Formatting into text happens only later, in
/// ``DiagnosticLog/export()``.
///
/// ```swift
/// log.record(DiagnosticEvent(.inputSeqBehind, surface: 7, a: localSeq, b: remoteSeq))
/// ```
public struct DiagnosticEvent: Sendable, Codable, Equatable {
    /// What kind of event this is.
    public var code: DiagnosticEventCode

    /// A monotonic timestamp, in nanoseconds, from a continuous clock.
    ///
    /// Sourced from `DispatchTime.now().uptimeNanoseconds` by the convenience
    /// initializer so two events are strictly orderable without depending on
    /// wall-clock skew. ``DiagnosticLog/export()`` writes one wall-clock anchor
    /// in its header so a reader can convert these back to absolute time.
    public var tNanos: UInt64

    /// An optional surface identifier the event relates to.
    public var surface: UInt32?

    /// An optional millisecond magnitude (e.g. silence duration, lag).
    public var ms: UInt32?

    /// First optional integer payload slot; meaning is per ``code``.
    public var a: Int?

    /// Second optional integer payload slot; meaning is per ``code``.
    public var b: Int?

    /// Third optional integer payload slot; meaning is per ``code``.
    public var c: Int?

    /// Creates an event with an explicit timestamp.
    ///
    /// - Parameters:
    ///   - code: The event kind.
    ///   - tNanos: A monotonic nanosecond timestamp.
    ///   - surface: An optional surface identifier.
    ///   - ms: An optional millisecond magnitude.
    ///   - a: First optional integer payload slot.
    ///   - b: Second optional integer payload slot.
    ///   - c: Third optional integer payload slot.
    public init(
        code: DiagnosticEventCode,
        tNanos: UInt64,
        surface: UInt32? = nil,
        ms: UInt32? = nil,
        a: Int? = nil,
        b: Int? = nil,
        c: Int? = nil
    ) {
        self.code = code
        self.tNanos = tNanos
        self.surface = surface
        self.ms = ms
        self.a = a
        self.b = b
        self.c = c
    }

    /// Creates an event stamped with the current monotonic time.
    ///
    /// Uses `DispatchTime.now().uptimeNanoseconds`, which is monotonic within a
    /// process run and cheap to read. This is the initializer hot-path call
    /// sites use; it does no allocation and no string work.
    ///
    /// - Parameters:
    ///   - code: The event kind.
    ///   - surface: An optional surface identifier.
    ///   - ms: An optional millisecond magnitude.
    ///   - a: First optional integer payload slot.
    ///   - b: Second optional integer payload slot.
    ///   - c: Third optional integer payload slot.
    public init(
        _ code: DiagnosticEventCode,
        surface: UInt32? = nil,
        ms: UInt32? = nil,
        a: Int? = nil,
        b: Int? = nil,
        c: Int? = nil
    ) {
        self.init(
            code: code,
            tNanos: DispatchTime.now().uptimeNanoseconds,
            surface: surface,
            ms: ms,
            a: a,
            b: b,
            c: c
        )
    }
}

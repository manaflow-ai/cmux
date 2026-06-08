import Foundation

/// A compact, stable identifier for one kind of diagnostic event.
///
/// The raw value is a small ``UInt16`` so a ``DiagnosticEvent`` stays tiny and
/// an exported log row is a few bytes instead of an interpolated string. New
/// cases append a fresh raw value and never renumber an existing one, so a blob
/// exported by an older build still decodes against a newer reader.
///
/// The cases cover the round-trip seams a dogfooder cares about: connection and
/// pairing outcome, render-grid liveness (silent re-subscribe / stream ended),
/// the input-sequence and byte-gap stalls that surface as "my keystrokes lag",
/// and a generic ``error`` bucket.
public enum DiagnosticEventCode: UInt16, Sendable, Codable, CaseIterable {
    /// A connection attempt to a paired Mac started.
    case connect = 1
    /// Pairing / attach completed successfully.
    case pairOk = 2
    /// Pairing / attach failed.
    case pairFail = 3
    /// The render-grid stream lagged behind (a bounded render-lag counter tick).
    ///
    /// Reserved for the render hot path in `GhosttySurfaceView` (the existing
    /// `oq.render.LAG` site). It is part of the export vocabulary now, but not
    /// emitted from the shell: instrumenting the per-frame render seam is a
    /// deeper injection deferred past P1, and the spec caps render-path
    /// instrumentation at a single bounded counter.
    case renderGridLag = 4
    /// The liveness watchdog forced a re-subscribe after a silent stream.
    case livenessResubscribe = 5
    /// The render-grid push stream ended and fell back to polling.
    case streamEnded = 6
    /// The local input sequence fell behind the remote-applied sequence.
    case inputSeqBehind = 7
    /// A gap was detected in the delivered terminal byte stream.
    case byteGap = 8
    /// A generic error at an instrumented seam.
    case error = 9
}

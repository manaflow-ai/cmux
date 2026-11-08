public import Foundation

/// Result of asking a transport to replace a silent control stream with a new
/// stream on the same native connection.
public enum CmxControlStreamRepairOutcome: Equatable, Sendable {
    /// The host's application layer answered on a fresh stream of the same
    /// connection, and that stream now carries the control lane. Bytes written
    /// before the replacement travelled on an older generation; `generation`
    /// identifies the replacement.
    case repaired(generation: UInt64)
    /// Positive evidence that the whole connection is silent: it has closed,
    /// or nothing from the host's application layer arrived on any stream of
    /// the connection since the silence began while liveness probes were
    /// running. The owner should close and redial.
    case connectionSilent
    /// No replacement and no conclusive evidence either way. The host may have
    /// refused the replacement (an older host), other lanes may still be
    /// delivering, or no activity signal exists. The owner keeps its
    /// conservative thresholds.
    case unavailable
}

/// A control-lane transport that can replace a stalled stream without closing
/// the native connection it shares with other lanes.
///
/// A control stream can go quiet while the connection underneath it keeps
/// carrying terminal output. Closing the whole connection in that state drops
/// every other lane and forces a full redial and replay; replacing only the
/// control stream costs about one round trip.
public protocol CmxByteTransportControlStreamRepairing: CmxByteTransport {
    /// Opens a fresh control stream on the same connection and installs it
    /// once the host's application layer acknowledges it.
    ///
    /// - Parameter silentSince: When the control stream last had a chance to
    ///   deliver. Evidence of whole-connection silence is judged from here.
    func repairControlStream(silentSince: ContinuousClock.Instant) async -> CmxControlStreamRepairOutcome

    /// Sends one frame and returns the control-stream generation it was
    /// written to. A frame written to a generation older than a later
    /// `repaired(generation:)` may never have reached the host.
    func sendReportingControlStreamGeneration(_ data: Data) async throws -> UInt64
}

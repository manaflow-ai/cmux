import Foundation

/// What resolved a previously detected terminal render stall.
public enum TerminalStallRecoveryCause: UInt8, Sendable, Codable, CaseIterable {
    /// A later frame caught the surface up and rendered normally.
    case catchupFrame = 1
    /// A replay acknowledgement cleared the barrier.
    case replayAck = 2
    /// A terminal output resync was triggered.
    case resync = 3
    /// The user explicitly requested a refresh or render reset.
    case manualRefresh = 4
    /// The user or network path forced a reconnect.
    case reconnect = 5
    /// The surface detached, so the episode is no longer relevant.
    case surfaceDetached = 6
    /// A barrier cleared for a non-ack reason.
    case barrierCleared = 7
}

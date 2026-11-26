import Foundation

/// Why a terminal replay was requested.
///
/// A replay is the only path that repaints a surface the phone has just
/// rebuilt blank, so the trigger is the difference between "the user is
/// looking at a blank terminal" and "the user is looking at slightly stale
/// text". Values are stable on the wire: they are packed into the terminal
/// trace's payload slot and read back in the analytics pipeline.
/// Raw values are never reused: a removed case leaves its number retired so a
/// newer producer cannot be misread as an older codepath.
public enum MobileTerminalReplayTrigger: Int, Sendable, Codable, CaseIterable {
    /// No reason was recorded. Nothing produces this today; it is the
    /// well-defined zero so an empty payload slot decodes without inventing a
    /// codepath.
    case unknown = 0
    /// The output stream reset; the surface was rebuilt blank.
    case outputReset = 1
    /// The render pipeline reset; the surface was rebuilt blank.
    case renderPipelineReset = 2
    /// A viewport transition armed a barrier and re-requested state.
    case viewportTransition = 3
    /// A render-grid delta did not chain onto the delivered revision.
    case revisionChainBreak = 4
    /// A render-grid delta did not chain onto the delivered history rows.
    case historyChainBreak = 5
    /// First attach to a surface with no delivered baseline.
    case coldAttach = 6
    /// A previous replay attempt failed or came back unusable.
    case failureRetry = 7
    /// The phone dropped a delivered frame before it reached the grid.
    case droppedFrame = 8
    /// The grid apply contract rejected a frame at paint time.
    case applyFenceFailure = 9
    /// Pending input never echoed, so the mirror is presumed diverged.
    case pendingInputDrop = 10
    /// The event subscription was re-established.
    case resubscribe = 11
    /// The Mac left the alternate screen, so the primary baseline is unknown.
    case screenTransition = 14
    /// A render-grid delta arrived with no delivered baseline to patch.
    case missingBaseline = 15
    /// A gap in the byte stream needs an authoritative screen to verify it.
    case byteGap = 16
}

/// Categorical context recorded alongside one replay trace.
///
/// The terminal trace event carries a single integer payload slot, so this
/// packs the fields that decide whether a slow replay is user-visible. The
/// encoding is stable on the wire and round-trips through ``encoded``.
public struct MobileTerminalReplayTraceContext: Equatable, Sendable {
    /// Highest retry attempt the encoding can represent.
    public static let maxAttempt = 15

    /// Why this replay was requested.
    public let trigger: MobileTerminalReplayTrigger
    /// Whether the surface had been rebuilt blank when the replay was
    /// requested. A slow replay on a blank surface is the blank-screen stall;
    /// a slow replay on a painted surface only holds back fresh output.
    public let surfaceIsBlank: Bool
    /// Whether a replay barrier is suppressing live output for this surface.
    public let barrierActive: Bool
    /// Zero-based retry index within the current replay episode.
    public let attempt: Int

    public init(
        trigger: MobileTerminalReplayTrigger,
        surfaceIsBlank: Bool,
        barrierActive: Bool,
        attempt: Int
    ) {
        self.trigger = trigger
        self.surfaceIsBlank = surfaceIsBlank
        self.barrierActive = barrierActive
        self.attempt = min(max(0, attempt), Self.maxAttempt)
    }

    /// Packs the context into one non-negative integer payload slot.
    public var encoded: Int {
        var value = trigger.rawValue & 0xFF
        if surfaceIsBlank { value |= 1 << 8 }
        if barrierActive { value |= 1 << 9 }
        value |= (attempt & 0xF) << 10
        return value
    }

    /// Unpacks a context previously produced by ``encoded``.
    ///
    /// Returns `nil` for a negative value or an unknown trigger so a future
    /// producer cannot be silently misread as `unknown` by an older consumer.
    public init?(encoded: Int) {
        guard encoded >= 0,
              let trigger = MobileTerminalReplayTrigger(rawValue: encoded & 0xFF) else {
            return nil
        }
        self.trigger = trigger
        self.surfaceIsBlank = (encoded & (1 << 8)) != 0
        self.barrierActive = (encoded & (1 << 9)) != 0
        self.attempt = (encoded >> 10) & 0xF
    }
}

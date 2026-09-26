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
    /// The replay retry budget for this surface ran out, so nothing is left
    /// asking the Mac for content.
    case retryExhausted = 17
    /// A stuck replay barrier was failed open. Live output resumes, but a
    /// surface rebuilt blank stays blank until output happens to arrive.
    case barrierFailedOpen = 18
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
    /// Whether a replay request is outstanding for this surface.
    public let replayInFlight: Bool
    /// Whether the surface has spent its replay retry budget. Combined with
    /// ``replayInFlight`` this separates "waiting on a repair" from "nothing
    /// is coming".
    public let retryExhausted: Bool
    /// Whether the app considered itself connected. A repair path that
    /// returns early on connection state leaves no other trace of the
    /// decision.
    public let isConnected: Bool
    /// Seconds since the last terminal event arrived, rounded down to a power
    /// of two; `nil` when nothing has ever arrived. This is the "is the lane
    /// alive" signal: a small age beside a blank surface means the transport
    /// is fine and the surface simply stopped asking.
    public let terminalEventAgeSeconds: Int?

    public init(
        trigger: MobileTerminalReplayTrigger,
        surfaceIsBlank: Bool,
        barrierActive: Bool,
        attempt: Int,
        replayInFlight: Bool = false,
        retryExhausted: Bool = false,
        isConnected: Bool = true,
        terminalEventAgeSeconds: Int? = nil
    ) {
        self.trigger = trigger
        self.surfaceIsBlank = surfaceIsBlank
        self.barrierActive = barrierActive
        self.attempt = min(max(0, attempt), Self.maxAttempt)
        self.replayInFlight = replayInFlight
        self.retryExhausted = retryExhausted
        self.isConnected = isConnected
        self.terminalEventAgeSeconds = terminalEventAgeSeconds.map {
            Self.bucketedSeconds($0)
        }
    }

    /// Rounds an age down to a power of two, capped at the encodable range.
    /// Exact seconds carry no diagnostic value here and would spend payload
    /// bits that the packed slot does not have.
    static func bucketedSeconds(_ seconds: Int) -> Int {
        guard seconds > 0 else { return 0 }
        var bucket = 0
        var value = 1
        while value * 2 <= seconds, bucket < Self.maxAgeExponent - 2 {
            value *= 2
            bucket += 1
        }
        return value
    }

    /// Exponent 0 means "nothing has ever arrived" and exponent 1 means "less
    /// than a second ago". Collapsing those two would report the freshest
    /// possible lane exactly like a lane that never delivered, which inverts
    /// the reading this field exists to give.
    static let maxAgeExponent = 15

    /// Packs the context into one non-negative integer payload slot.
    public var encoded: Int {
        var value = trigger.rawValue & 0xFF
        if surfaceIsBlank { value |= 1 << 8 }
        if barrierActive { value |= 1 << 9 }
        value |= (attempt & 0xF) << 10
        if replayInFlight { value |= 1 << 14 }
        if retryExhausted { value |= 1 << 15 }
        if isConnected { value |= 1 << 16 }
        value |= (Self.ageExponent(terminalEventAgeSeconds) & 0xF) << 17
        return value
    }

    /// 0 means absent, 1 means sub-second, and higher values are the
    /// exponent of the power-of-two bucket offset by that reservation.
    static func ageExponent(_ seconds: Int?) -> Int {
        guard let seconds else { return 0 }
        guard seconds > 0 else { return 1 }
        var exponent = 2
        var value = 1
        while value * 2 <= seconds, exponent < maxAgeExponent {
            value *= 2
            exponent += 1
        }
        return exponent
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
        self.replayInFlight = (encoded & (1 << 14)) != 0
        self.retryExhausted = (encoded & (1 << 15)) != 0
        self.isConnected = (encoded & (1 << 16)) != 0
        let exponent = (encoded >> 17) & 0xF
        self.terminalEventAgeSeconds = switch exponent {
        case 0: nil
        case 1: 0
        default: 1 << (exponent - 2)
        }
    }
}

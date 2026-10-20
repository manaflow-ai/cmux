import CmuxCloudTui
import Foundation

/// When a native cloud pane shows its connection card.
///
/// The pane never shows a progress card: an attachment that is connecting or
/// reconnecting keeps its last frame (or stays blank when brand new) and simply
/// fills in when the stream is usable. A byte attachment normally becomes usable
/// within a few hundred milliseconds, and the provider re-runs `reconnect` on
/// every graph refresh, so any card on the first `.connecting` or
/// `.disconnected` sample flashed for the duration of a healthy handoff and
/// called a pane "unavailable" that automatic recovery repaired a moment later.
/// The only card is the actionable one: Reconnect, shown once automatic
/// recovery has kept failing for `failureGrace`, or at once when recovery has
/// been given up. A usable attachment clears it immediately.
public struct CloudTerminalConnectionPresentationPolicy: Equatable, Sendable {
    /// How long automatic recovery may keep failing before the pane offers Reconnect.
    public let failureGrace: Duration

    public init(failureGrace: Duration) {
        precondition(failureGrace >= .zero)
        self.failureGrace = failureGrace
    }

    /// Production bound: a few rounds of the provider's attachment backoff.
    public static let standard = Self(failureGrace: .seconds(8))

    /// No grace: a disconnected attachment offers Reconnect at once. For tests
    /// that assert card content rather than timing.
    public static let immediate = Self(failureGrace: .zero)

    /// How long the current unusable episode has lasted, as the session tracks it.
    public enum Stage: Equatable, Sendable {
        /// Shorter than `failureGrace`: show nothing.
        case silent
        /// Past `failureGrace`: a disconnected attachment offers Reconnect.
        case failure
    }

    public enum Outcome: Equatable, Sendable {
        case none
        case failure
    }

    public struct Input: Equatable, Sendable {
        public init(
            phase: CloudTuiManualMirrorPhase,
            replayReceived: Bool,
            automaticRecovery: Bool,
            stage: Stage
        ) {
            self.phase = phase
            self.replayReceived = replayReceived
            self.automaticRecovery = automaticRecovery
            self.stage = stage
        }

        public var phase: CloudTuiManualMirrorPhase
        public var replayReceived: Bool
        /// Whether the session or its provider will retry on its own.
        public var automaticRecovery: Bool
        public var stage: Stage
    }

    /// Whether `input` describes an attachment the user can type into.
    public static func isUsable(_ input: Input) -> Bool {
        input.phase == .attached && input.replayReceived
    }

    /// Whether `input` is an episode the stage timer should be measuring.
    public static func isUnusableEpisode(_ input: Input) -> Bool {
        switch input.phase {
        case .idle, .stopped: return false
        case .connecting, .disconnected: return true
        case .attached: return !input.replayReceived
        }
    }

    public static func outcome(for input: Input) -> Outcome {
        switch input.phase {
        case .idle, .stopped, .connecting, .attached:
            // Never started, cancelled by the user, or still being worked on:
            // nothing to report; the pane fills in when the stream is usable.
            return .none
        case .disconnected:
            guard input.automaticRecovery else { return .failure }
            return input.stage == .failure ? .failure : .none
        }
    }
}

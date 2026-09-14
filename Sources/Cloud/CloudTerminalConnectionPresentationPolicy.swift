import Foundation

/// When a native cloud pane shows its connection card, and which one.
///
/// A byte attachment normally becomes usable within a few hundred milliseconds,
/// and the provider re-runs `reconnect` on every graph refresh, so a card that
/// appears on the first `.connecting` or `.disconnected` sample flashes for the
/// duration of a healthy handoff and shows "unavailable" for a disconnect that
/// automatic recovery repairs a moment later. The card therefore waits: nothing
/// while the attachment has been unusable for less than `progressGrace`, a
/// progress card after that while recovery is automatic, and the Reconnect card
/// only once automatic recovery has kept failing for `failureGrace` or was given
/// up. A usable attachment clears the card at once.
struct CloudTerminalConnectionPresentationPolicy: Equatable, Sendable {
    /// How long an unusable attachment stays silent before the pane shows progress.
    let progressGrace: Duration
    /// How long automatic recovery may keep failing before the pane offers Reconnect.
    let failureGrace: Duration

    init(progressGrace: Duration, failureGrace: Duration) {
        precondition(progressGrace >= .zero)
        precondition(failureGrace >= progressGrace)
        self.progressGrace = progressGrace
        self.failureGrace = failureGrace
    }

    /// Production bounds: a first attach or a reconnect that lands inside the
    /// progress grace never shows a card; a machine that keeps failing for
    /// longer than a few retry rounds is reported with a manual Reconnect.
    static let standard = Self(progressGrace: .milliseconds(1_200), failureGrace: .seconds(8))

    /// No grace at all: every unusable sample shows its card at once. For tests
    /// that assert card content rather than timing.
    static let immediate = Self(progressGrace: .zero, failureGrace: .zero)

    /// How long the current unusable episode has lasted, as the session tracks it.
    enum Stage: Equatable, Sendable {
        /// Shorter than `progressGrace`: show nothing.
        case silent
        /// Past `progressGrace`: show progress while recovery continues.
        case progress
        /// Past `failureGrace`: a disconnected attachment offers Reconnect.
        case failure
    }

    enum Outcome: Equatable, Sendable {
        case none
        /// `reconnecting` is true once the pane has shown remote content, so the
        /// card can say "reconnecting" instead of "connecting".
        case progress(reconnecting: Bool)
        case failure
    }

    struct Input: Equatable, Sendable {
        var phase: CloudTuiManualMirrorPhase
        var replayReceived: Bool
        var hasEverReplayed: Bool
        /// Whether the session or its provider will retry on its own.
        var automaticRecovery: Bool
        var stage: Stage
    }

    /// Whether `input` describes an attachment the user can type into.
    static func isUsable(_ input: Input) -> Bool {
        input.phase == .attached && input.replayReceived
    }

    /// Whether `input` is an episode the stage timers should be measuring.
    static func isUnusableEpisode(_ input: Input) -> Bool {
        switch input.phase {
        case .idle, .stopped: return false
        case .connecting, .disconnected: return true
        case .attached: return !input.replayReceived
        }
    }

    static func outcome(for input: Input) -> Outcome {
        switch input.phase {
        case .idle, .stopped:
            // Never started, or the user cancelled the attempt: nothing to report.
            return .none
        case .attached where input.replayReceived:
            return .none
        case .attached, .connecting:
            return input.stage == .silent ? .none : .progress(reconnecting: input.hasEverReplayed)
        case .disconnected:
            guard input.automaticRecovery else { return .failure }
            switch input.stage {
            case .silent: return .none
            case .progress: return .progress(reconnecting: input.hasEverReplayed)
            case .failure: return .failure
            }
        }
    }
}

public import CmuxUpdater

/// What an install the person follows on the notice card is doing, so the
/// card never says "relaunches in a moment" for a minute (a583, Lawrence
/// 2026-10-23: the card sat on Installing Update for about 80 s while
/// Sparkle's installer checked the new version before it relaunched).
nonisolated public struct UpdateInstallStatus: Equatable, Sendable {
    /// The part of the install that runs now.
    public enum Stage: Equatable, Sendable {
        /// Sparkle's installer prepares the new version and checks its
        /// signature; cmux relaunches when it is done.
        case preparing
        /// The relaunch gate holds the relaunch for busy agents or running
        /// commands (``UpdateRelaunchBlockers``).
        case waiting(agents: Int, commands: Int)
        /// No relaunch after ``UpdateInstallStatus/giveUpAfter``: the
        /// windows come back and the card says so.
        case stalled
    }

    /// How long the plain "relaunches in a moment" text stays.
    public static let slowAfter: Duration = .seconds(10)
    /// How long an install may go without a relaunch before it counts as stuck.
    public static let giveUpAfter: Duration = .seconds(180)

    public var stage: Stage
    /// Whole seconds since the install started.
    public var seconds: Int

    /// The status after `elapsed`, with the relaunch gate's hold when it holds one.
    ///
    /// - Parameters:
    ///   - elapsed: the time since the install started.
    ///   - blockers: what the relaunch gate waits for, or nil when it holds nothing.
    public init(elapsed: Duration, blockers: UpdateRelaunchBlockers?) {
        seconds = Int(elapsed.components.seconds)
        if let blockers, blockers.busyAgentCount > 0 || blockers.runningCommandCount > 0 {
            // The gate's Relaunch (Install Now) ends this wait, so it never gives up on its own.
            stage = .waiting(agents: blockers.busyAgentCount, commands: blockers.runningCommandCount)
        } else if elapsed >= Self.giveUpAfter {
            stage = .stalled
        } else {
            stage = .preparing
        }
    }

    /// Past ``slowAfter``: the card names the step and the seconds.
    public var isSlow: Bool { Duration.seconds(seconds) >= Self.slowAfter }
}

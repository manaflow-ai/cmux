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

    /// The status after `elapsed` since the install started. A relaunch the gate holds is
    /// never an install the person waits on: it shows as the staged update.
    public init(elapsed: Duration) {
        seconds = Int(elapsed.components.seconds)
        if elapsed >= Self.giveUpAfter {
            stage = .stalled
        } else {
            stage = .preparing
        }
    }

    /// Past ``slowAfter``: the card names the step and the seconds.
    public var isSlow: Bool { Duration.seconds(seconds) >= Self.slowAfter }
}

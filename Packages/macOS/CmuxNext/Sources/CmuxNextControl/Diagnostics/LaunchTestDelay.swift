import CmuxNextWakeups
public import Foundation

/// The launch bench's positive control (scripts/measure/launch-tti.sh `control=MS`): with
/// `CMUX_NEXT_LAUNCH_TEST_DELAY_MS=N` the launch waits N ms before it makes any window, so every startup number
/// the bench reads (first frame, first chat paint, launch to interaction) must come out about N ms later. A bench
/// whose numbers do not move by that much cannot see a regression either, and fails. Read once at launch; off (nil)
/// unless set to a positive whole number of ms; clamped to `limit`. The `CMUX_NEXT_` prefix keeps it through
/// LaunchIdentity.stripInheritedEnvironment, which drops other inherited `CMUX` variables.
///
/// Leo: "we need to have proper measurments and goals for startup times and just to be doing them. figure out any
/// sort of way."
public struct LaunchTestDelay: Equatable, Sendable {
    public static let variable = "CMUX_NEXT_LAUNCH_TEST_DELAY_MS"
    /// The longest delay a launch takes, whatever the variable says.
    public static let limit = 5000

    public let milliseconds: Int

    /// Nil unless `environment` sets the variable to a whole number above zero; values above `limit` are `limit`.
    public init?(environment: [String: String]) {
        guard let text = environment[Self.variable]?.trimmingCharacters(in: .whitespaces), let value = Int(text),
              value > 0 else { return nil }
        milliseconds = min(value, Self.limit)
    }

    public var duration: Duration { .milliseconds(milliseconds) }

    /// Waits `duration` on a one-shot DemandTimer deadline (a launch's only wait for it; nothing polls).
    public func elapse(clock: any Clock<Duration> = ContinuousClock()) async {
        let timer = DemandTimer(owner: "launch.test_delay", clock: clock)
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in timer.schedule(after: duration) { done.resume() } }
        timer.cancel() // after the fire, a no-op; it keeps the timer alive until then (its deadline task holds it weakly)
    }

    /// At launch, before any window: the wait when `environment` asks for one, between the launch marks
    /// `launch_test_delay_start` and `launch_test_delay_end`. Throws only when the launch was cancelled meanwhile (Quit).
    @MainActor public static func atLaunch(environment: [String: String] = ProcessInfo.processInfo.environment,
                                         mark: (String) -> Void) async throws {
        guard let delay = LaunchTestDelay(environment: environment) else { return }
        mark("launch_test_delay_start")
        await delay.elapse()
        mark("launch_test_delay_end")
        try Task.checkCancellation()
    }
}

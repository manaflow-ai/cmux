/// The launch after a run that ended without a quit (`kill -9`, jetsam, a crash, power loss): the daemon usually kept
/// every terminal running (`DaemonService.launchAttach` is `.reattached`), so each terminal draws the screen the daemon
/// holds.
///
/// The terminal frames on disk were saved by the last quit, an earlier run than the one that ended: drawn over the
/// terminals until their live content came, they showed older screens that the live ones then replaced (a visible
/// rebuild). With feature `relaunchReattach` such a launch drops them before any window mounts a pane, and each
/// terminal stays held clear until its live screen draws, as a terminal with no saved frame does. Chrome restores
/// a crashed session from the session file it writes while it runs (chrome/browser/sessions/session_service.cc),
/// never from an earlier session's; the unclean end is its clean-exit beacon's (components/metrics/clean_exit_beacon.cc).
///
/// ```swift
/// RelaunchReattach(previousRunEndedUnasked: marker?.previousExit != nil, enabled: features.isEnabled(.relaunchReattach))
///     .apply(discardSavedFrames: { frames.discardLaunchRead() }, mark: { DebugTimings.markLaunch($0) })
/// ```
public struct RelaunchReattach: Sendable {
    /// The previous run ended with no quit anyone asked for (the run marker's unclean exit).
    public let previousRunEndedUnasked: Bool
    /// Feature `relaunchReattach`.
    public let enabled: Bool

    /// The launch mark of a launch that dropped the earlier quit's frames (bench_launch.py `after-kill`).
    public static let skippedFramesMark = "relaunch.saved_frames_skipped"

    public init(previousRunEndedUnasked: Bool, enabled: Bool) {
        self.previousRunEndedUnasked = previousRunEndedUnasked
        self.enabled = enabled
    }

    /// Whether the saved terminal frames are the previous run's last screens: only a quit saves them.
    public var keepsSavedFrames: Bool { !enabled || !previousRunEndedUnasked }

    /// Runs `discardSavedFrames` when the saved frames are not the previous run's last screens, then records
    /// ``skippedFramesMark`` through `mark`. Call before the first window mounts a pane.
    public func apply(discardSavedFrames: () -> Void, mark: (String) -> Void) {
        guard !keepsSavedFrames else { return }
        discardSavedFrames()
        mark(Self.skippedFramesMark)
    }
}

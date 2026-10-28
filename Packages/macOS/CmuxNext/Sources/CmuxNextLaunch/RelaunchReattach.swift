/// The launch after a run that ended without a quit while its daemon kept running (`kill -9`, jetsam, Force Quit, a
/// crash): every terminal is still alive in the daemon (`DaemonService.launchAttach` is `.reattached`), so each one
/// draws the screen the daemon holds.
///
/// The terminal frames and the front window's picture on disk were saved by the last quit, an earlier run than the one
/// that ended: drawn first, they showed older screens that the live ones then replaced (a visible rebuild). With
/// feature `relaunchReattach` such a launch shows neither (``keepsSavedScreens``) and each terminal stays held clear
/// until its live screen draws. After a system shutdown nothing the run left is running, so the saved screens stay:
/// they are better than a blank pane through a cold daemon start. Chrome restores a crashed session from the session
/// file it writes while it runs (chrome/browser/sessions/session_service.cc), never from an earlier session's, and
/// counts an unclean exit at the end of a system session apart (components/metrics/stability_metrics_provider.cc).
///
/// Before each window's first frame the launch also takes over what the ended run left (``Steps``): the daemon output
/// ring of every restored terminal and the Chromium Host that kept its pages.
///
/// ```swift
/// let reattach = RelaunchReattach(previousEnd: .killed, enabled: features.isEnabled(.relaunchReattach))
/// reattach.apply(steps: steps, discardSavedFrames: { frames.discardLaunchRead() }, mark: { DebugTimings.markLaunch($0) })
/// let facts = WindowPictureStore.LaunchFacts(savedPicture: true, recovered: false, incognitoLeftovers: false,
///                                            savedScreensStale: !reattach.keepsSavedScreens)
/// ```
public struct RelaunchReattach: Sendable, Equatable {
    /// How the previous run ended, seen from this launch (the run marker's unclean exit).
    public enum PreviousEnd: Sendable, Equatable {
        /// It quit as asked, or this is the first launch: what is on disk is its last screens.
        case quit
        /// It ended with no handler running in this boot (`kill -9`, jetsam, Force Quit, a fatal hang): its daemon and
        /// Chromium Host still run.
        case killed
        /// Its fatal signal handler ran or an exception ended it: its daemon still runs.
        case crashed
        /// The Mac restarted after it (a new boot session): nothing it left runs.
        case systemShutdown
    }

    /// What one launch step did (``Steps``).
    public enum StepResult: Sendable, Equatable {
        /// The step began.
        case started
        /// The step's dependency is not in this build: the launch goes on without it.
        case unavailable
    }

    /// The steps that take over what the ended run left, run before any window's first frame. The app passes the
    /// real ones; ``Steps/unavailable`` stands in while a dependency is not in the build.
    public struct Steps: Sendable {
        /// Maps the daemon output ring of each terminal the launch restores (`TerminalOutputRing`,
        /// mapped read-only by the daemon connection's `TerminalOutputRingMapping`), so its first screen is read from
        /// the ring the daemon kept writing.
        public var mapTerminalRings: @MainActor @Sendable () -> StepResult
        /// Adopts the Chromium Host the ended run left (`ChromiumHostAdoption`, feature
        /// `chromiumHostSurvivesAppCrash`), so the restored pages keep their renderers.
        public var adoptBrowserHost: @MainActor @Sendable () -> StepResult

        public init(mapTerminalRings: @escaping @MainActor @Sendable () -> StepResult,
                    adoptBrowserHost: @escaping @MainActor @Sendable () -> StepResult) {
            self.mapTerminalRings = mapTerminalRings
            self.adoptBrowserHost = adoptBrowserHost
        }

        /// A build without p01-process-131 and p01-process-150: each step says ``StepResult/unavailable``.
        public static let unavailable = Steps(mapTerminalRings: { .unavailable }, adoptBrowserHost: { .unavailable })
    }

    /// The launch dropped the earlier quit's terminal frames (bench_launch.py `after-kill` reads these marks).
    public static let skippedFramesMark = "relaunch.saved_frames_skipped"
    /// The ring mapping began, or its dependency is not in the build.
    public static let ringsMappingMark = "relaunch.rings_mapping"
    public static let ringsUnavailableMark = "relaunch.rings_unavailable"
    /// The host adoption began, or its dependency is not in the build.
    public static let hostAdoptingMark = "relaunch.host_adopting"
    public static let hostUnavailableMark = "relaunch.host_unavailable"

    public let previousEnd: PreviousEnd
    /// Feature `relaunchReattach`.
    public let enabled: Bool

    public init(previousEnd: PreviousEnd, enabled: Bool) {
        self.previousEnd = previousEnd
        self.enabled = enabled
    }

    /// The launch takes over the running daemon the previous run left: the feature is on and that run ended in this
    /// boot without a quit.
    public var reattaches: Bool {
        guard enabled else { return false }
        return previousEnd == .killed || previousEnd == .crashed
    }

    /// Whether the last quit's screens may show first: its terminal frames and its window picture, whose terminal
    /// regions are the same screens. False when the launch reattaches: the live screens are newer.
    public var keepsSavedScreens: Bool { !reattaches }

    /// When the launch reattaches: drops the saved terminal frames, then runs `steps`, recording each through `mark`.
    /// Call once, before the first window mounts a pane.
    @MainActor
    public func apply(steps: Steps, discardSavedFrames: () -> Void, mark: (String) -> Void) {
        guard reattaches else { return }
        discardSavedFrames()
        mark(Self.skippedFramesMark)
        mark(steps.mapTerminalRings() == .started ? Self.ringsMappingMark : Self.ringsUnavailableMark)
        mark(steps.adoptBrowserHost() == .started ? Self.hostAdoptingMark : Self.hostUnavailableMark)
    }
}

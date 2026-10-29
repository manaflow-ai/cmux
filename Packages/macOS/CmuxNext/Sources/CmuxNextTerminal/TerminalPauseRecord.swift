import AppKit
public import CmuxNextDesign
import CmuxNextWakeups

/// What one draw-pause computation read and gave (`debug.surfaces` `surface.pause_record`).
public nonisolated struct TerminalPauseComputation: Sendable, Equatable {
    /// `CLOCK_UPTIME_RAW` nanoseconds of the computation.
    public var atNanos: UInt64
    /// The call site that asked for it (`file:line function`).
    public var caller: String
    /// The pause it gave (``SurfacePause`` raw value), nil: draws.
    public var pause: String?
    public var inputs: SurfaceDrawInputs
    /// Its window's ``WindowOcclusionFamily`` said occluded (nil: no family installed).
    public var familyOccluded: Bool?
    /// The surface was shown (its window node) and watched its window's notices then.
    public var shown: Bool
    public var watchingWindow: Bool

    public init(atNanos: UInt64, caller: String, pause: String?, inputs: SurfaceDrawInputs, familyOccluded: Bool?,
                shown: Bool, watchingWindow: Bool) {
        self.atNanos = atNanos
        self.caller = caller
        self.pause = pause
        self.inputs = inputs
        self.familyOccluded = familyOccluded
        self.shown = shown
        self.watchingWindow = watchingWindow
    }
}

/// The last pause computations of a surface and what the inputs give now, read together.
public nonisolated struct TerminalPauseRecordReport: Sendable, Equatable {
    /// Oldest first, at most ``TerminalPauseRecord/capacity``.
    public var computations: [TerminalPauseComputation]
    /// The same inputs read now, with no side effect: the pause they would give.
    public var now: TerminalPauseComputation
    /// The stored pause differs from what the inputs give now: nothing recomputed after the inputs changed.
    public var stale: Bool

    public init(computations: [TerminalPauseComputation], now: TerminalPauseComputation, stale: Bool) {
        self.computations = computations
        self.now = now
        self.stale = stale
    }
}

/// The ring of a surface's last pause computations, in DEBUG and bench builds only: record only, written on the main
/// thread in `updateOcclusion` (where every pause is computed), read by `debug.surfaces`. A visible terminal stayed
/// paused `hidden` (v2.2.5-opt) or `window_occluded` (v2.2.6-opt) while nothing hid or covered it, and three unit orders
/// did not reproduce it: the record names the caller and inputs of the computation that left the pause, and the read
/// says whether the pause is stale (handoff/v224-gate-triage.md).
nonisolated struct TerminalPauseRecord: Sendable {
    /// Computations kept per surface.
    static let capacity = 6
    private(set) var computations: [TerminalPauseComputation] = []

    mutating func append(_ computation: TerminalPauseComputation) {
        if computations.count == Self.capacity { computations.removeFirst() }
        computations.append(computation)
    }
}

extension TerminalSurfaceView {
    /// The draw inputs and their pause now, as `updateOcclusion` reads them (the window's occlusion family
    /// included), with no side effect.
    func currentPauseInputs() -> (inputs: SurfaceDrawInputs, familyOccluded: Bool?) {
        var inputs = WindowDrawPolicy.inputs(for: self, suspended: isRenderingSuspended, forced: mirrorDemand > 0)
        let family = window.flatMap(WindowOcclusionFamily.installed(on:))?.isOccluded
        if family == true { inputs.windowVisible = false }
        return (inputs, family)
    }

    /// The last pause computations and the pause the inputs give now; nil in Release builds.
    var pauseRecordReport: TerminalPauseRecordReport? {
        #if DEBUG || CMUX_BENCH_HOOKS
        let (inputs, family) = currentPauseInputs()
        let now = TerminalPauseComputation(atNanos: clock_gettime_nsec_np(CLOCK_UPTIME_RAW), caller: "debug.surfaces (now)",
                                           pause: inputs.pause?.rawValue, inputs: inputs, familyOccluded: family,
                                           shown: isShown, watchingWindow: isWatchingWindow)
        return TerminalPauseRecordReport(computations: pauseRecord.computations, now: now,
                                         stale: surface != nil && now.pause != pause?.rawValue)
        #else
        return nil
        #endif
    }
}

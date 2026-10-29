#if DEBUG || CMUX_BENCH_HOOKS
public import CmuxNextInputCore
public import CmuxNextWakeups
import Darwin
import Foundation

/// The app's input-turn hop recorder (machine queue MQ-input-turn-hops), owned by
/// the app's control wiring: one ``InputTurnHopRecorder`` that `debug.input` action `hops`
/// reads, and the main run loop's ``InputTurnCalloutTimer`` that records its non-Swift lane, with
/// a ``CalloutStackSampler`` that samples the main thread (``ThreadStackSampler``) to name a long
/// callout. Nothing in the app records its Swift lane since the MainJobGate hook was deleted
/// (sequence-manager S6); the main-job census's input window names those jobs.
///
/// ```swift
/// let hops = InputTurnHops()
/// router.register([DebugInput(sources: sources, recorders: [hops.start(input: inputTap)]).method])
/// ```
@MainActor
public final class InputTurnHops {
    /// Deep enough to reach the run loop's callout frame below AppKit and SwiftUI frames.
    static let sampledFrames = 160

    /// The one recorder of the app.
    public let recorder = InputTurnHopRecorder()
    private var calloutTimer: InputTurnCalloutTimer?

    public init() {}

    /// Starts timing the main run loop's callouts (once; on the main thread, whose stack the
    /// sampler reads) and returns the recorder for `debug.input`. The input turn is the pending
    /// input the window server reports for the app of `input` (``SessionInputPending``).
    public func start(input: any InputObserving) -> InputTurnHopRecorder {
        guard calloutTimer == nil else { return recorder }
        let pending = SessionInputPending(events: WindowServerInputEvents(input: input))
        let mainStack = ThreadStackSampler(thread: mach_thread_self(), maxFrames: Self.sampledFrames)
        calloutTimer = InputTurnCalloutTimer(diagnostics: recorder, sampler: CalloutStackSampler { mainStack.sample() }) {
            InputTurnHopRecorder.InputTurn(pending: pending.pendingKinds(uptime: ProcessInfo.processInfo.systemUptime), dispatching: false)
        }
        return recorder
    }
}
#endif

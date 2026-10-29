#if DEBUG || CMUX_BENCH_HOOKS
public import CmuxNextInputCore
public import CmuxNextWakeups
import Darwin
import Foundation

/// The app's input-turn hop recorder (machine queue MQ-input-turn-hops), owned by
/// the app's control wiring: one ``MainJobGateDiagnostics`` that `debug.input` action `hops`
/// reads, and the main run loop's ``InputTurnCalloutTimer`` that records its non-Swift lane, with
/// a ``CalloutStackSampler`` that samples the main thread (``ThreadStackSampler``) to name a long
/// callout. The MainJobGate hook records the Swift lane into ``recorder`` when it
/// installs.
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
    public let recorder = MainJobGateDiagnostics()
    private var calloutTimer: InputTurnCalloutTimer?

    public init() {}

    /// Starts timing the main run loop's callouts (once; on the main thread, whose stack the
    /// sampler reads) and returns the recorder for `debug.input`. The input turn is the pending
    /// input the window server reports for the app of `input` (``SessionInputPending``);
    /// p04-input-021's pending-input state replaces it with one atomic load and adds the
    /// dispatching turns.
    public func start(input: any InputObserving) -> MainJobGateDiagnostics {
        guard calloutTimer == nil else { return recorder }
        let pending = SessionInputPending(events: WindowServerInputEvents(input: input))
        let mainStack = ThreadStackSampler(thread: mach_thread_self(), maxFrames: Self.sampledFrames)
        calloutTimer = InputTurnCalloutTimer(diagnostics: recorder, sampler: CalloutStackSampler { mainStack.sample() }) {
            MainJobGateDiagnostics.InputTurn(pending: pending.pendingKinds(uptime: ProcessInfo.processInfo.systemUptime), dispatching: false)
        }
        return recorder
    }
}
#endif

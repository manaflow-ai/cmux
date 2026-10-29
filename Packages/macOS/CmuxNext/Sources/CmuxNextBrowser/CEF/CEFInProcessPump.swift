import CmuxNextInput
import CmuxNextWakeups
import Foundation
import os

/// The in-process backend's external message pump: `CefDoMessageLoopWork` on the main thread when CEF
/// asks (`CefSettings.external_message_pump`). Only `CEFRuntime`'s in-process initialize
/// (``CEFRuntimeBoot/inProcess(_:)``) makes one, before `CefInitialize`, and only then does initialize
/// give the shim a schedule callback. In host mode there is none: the Chromium Host runs
/// `CefRunMessageLoop` (browser_host_main.mm), as Chrome's browser process owns its UI-thread loop
/// (content/browser/browser_main_loop.cc), and the app makes no ``CEFMessagePump`` or ``CEFPumpTimer``.
final class CEFInProcessPump {
    /// Makes the pump's one timer on the main thread's deadline queue.
    typealias MakeTimer = @MainActor (MainWakeUpQueue) -> any CEFPumpTimer

    let pump: CEFMessagePump

    /// The pump's timer outside tests: a ``CEFWakeUpQueuePumpTimer`` on `queue`.
    static func wakeUpQueueTimer(_ queue: MainWakeUpQueue) -> any CEFPumpTimer {
        CEFWakeUpQueuePumpTimer(queue: queue)
    }

    /// Asks the fork for its delayed work as absolute run times and makes the pump, not yet started.
    /// - Parameters:
    ///   - shim: The in-process shim, before `CefInitialize` (no request comes before it).
    ///   - wakeUps: The main thread's deadline queue the timer arms on.
    ///   - gate: The runtime's gate for requests from Chromium threads (they find it through the callback context).
    ///   - makeTimer: Makes the pump's one timer (a test's counter).
    ///   - inputPolicy: The input policy (feature `cefPumpInputPolicy`); nil never holds for input.
    ///   - crashKeys: The app's crash keys: each pass runs with Chromium's state at `inPump` (nil: none).
    ///   - frames: What the frame-deadline slices read (feature `cefPumpFrameDeadline`); nil: every pass
    ///     runs at the fork's static slice.
    ///   - input: The app's input tap, whose dispatch ends the frame deadline follows for page input.
    ///   - work: One pump pass.
    init(shim: CEFShimLibrary, wakeUps: MainWakeUpQueue, gate: CEFPumpCrossThreadGate, makeTimer: MakeTimer,
         inputPolicy: CEFPumpInputPolicy?, crashKeys: CrashKeySlots?, frames: CEFPumpFrameSeams? = nil,
         input: InputEventTap? = nil, logger: Logger, work: @escaping () -> Void) {
        let forkAPI = shim.forkAPIVersion()
        if forkAPI < CEFPumpSchedule.demandDrivenForkAPI {
            logger.error("CEF fork API \(forkAPI) predates the demand-driven pump (\(CEFPumpSchedule.demandDrivenForkAPI)): work left after a time slice and delayed tasks posted during a pass wait for the next CEF request, so pages may stall")
        }
        // CEF's delayed work as absolute run times with Chromium's leeway; older forks
        // keep the ms path.
        // SAFETY: the callback is a C function of `cmux_shim_schedule_delayed_fn`; its context is the runtime
        // `initialize` was given, which lives for the process once started.
        let absoluteRunTimes = unsafe shim.setScheduleDelayed(cefScheduleDelayedCallback) == 1
        logger.notice("CEF pump delayed work: \(absoluteRunTimes ? "absolute run times" : "whole milliseconds", privacy: .public)")
        let timeSlice = CEFPumpSchedule.timeSlice(forkAPI: forkAPI)
        pump = CEFMessagePump(work: work, timer: makeTimer(wakeUps), timeSlice: timeSlice,
                              gate: gate, absoluteRunTimes: absoluteRunTimes, crashKeys: crashKeys)
        if let inputPolicy { pump.setInputPolicy(inputPolicy) }
        if let frames {
            let dispatches = input.map { CEFPumpTapDispatches(tap: $0) as any CEFPumpInputDispatches }
            pump.setFrameDeadline(Self.frameDeadline(shim: shim, frames: frames, cap: timeSlice, dispatches: dispatches, logger: logger))
        }
    }

    /// The pump's frame-deadline slices. A fork without
    /// `cmux_set_message_loop_time_slice` (the shim answers 0 to a 0 slice, which changes nothing) keeps
    /// the static `--cmux-pump-time-slice-us` for every pass; its passes still wait for input turns.
    static func frameDeadline(shim: CEFShimLibrary, frames: CEFPumpFrameSeams, cap: TimeInterval,
                              dispatches: (any CEFPumpInputDispatches)?, logger: Logger) -> CEFPumpFrameDeadline {
        let setPumpTimeSlice = shim.setPumpTimeSlice
        let perCall = setPumpTimeSlice(0) == 1
        logger.notice("CEF pump slice: \(perCall ? "to the frame deadline" : "the static switch (the fork has no per-call slice)", privacy: .public)")
        let pages = ChromiumPageWindowClassifier()
        return CEFPumpFrameDeadline(seams: frames, cap: cap, setSlice: perCall ? { _ = setPumpTimeSlice($0) } : nil,
                                    pageHasKeyboard: CEFPumpBoard.keyWindowIsPage(pages: pages), dispatches: dispatches)
    }
}

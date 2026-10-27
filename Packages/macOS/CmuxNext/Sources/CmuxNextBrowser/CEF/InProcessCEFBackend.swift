import CmuxNextInput
import CmuxNextWakeups
public import Foundation
import os

/// The in-process Chromium backend (``BrowserBackend/inProcess``): the one owner of everything the app
/// runs only while Chromium's browser process is this process. That is the NSApp check
/// (`CefAppProtocol`, which the app's NSApplication adopts) and the external message pump:
/// `CefDoMessageLoopWork` on the main thread when CEF asks (`CefSettings.external_message_pump`), with
/// its schedule, timer, cross-thread gate and counters. Only `CEFRuntime`'s in-process initialize
/// (``CEFRuntimeBoot/inProcess(_:)``) makes one, before `CefInitialize`, and only then does initialize
/// give the shim a schedule callback.
///
/// In host mode there is none: the Chromium Host runs `CefRunMessageLoop` (browser_host_main.mm), as
/// Chrome's browser process owns its UI-thread loop (content/browser/browser_main_loop.cc), and the app
/// never reaches a pump type. Deleting this backend, with the CmuxNextMallocZone target and the app's
/// ``InProcessCEFApplication`` conformance, is the follow-up after host mode is on by default in Release
/// (plans/cmux-next/chrome-parity/p01-process.md, task 102).
public final class InProcessCEFBackend {
    /// The pump's counters since `CefInitialize` (`debug.cef` `pump`, `debug.input` `pump`).
    public typealias Stats = CEFPumpStats
    /// What Chromium threads ask whether a delayed request must wake the main thread. The runtime owns
    /// one from its creation, because the shim's callbacks reach it off the main thread by the runtime's
    /// token before and after this backend exists.
    typealias RequestGate = CEFPumpCrossThreadGate
    /// Makes the pump's one timer on the main thread's deadline queue.
    typealias MakeTimer = @MainActor (MainWakeUpQueue) -> any CEFPumpTimer

    /// The pump the shim's schedule callbacks deliver to (``CEFPumpRequestDelivery``).
    let pump: CEFMessagePump

    /// The pump's timer outside tests: a ``CEFWakeUpQueuePumpTimer`` on `queue`.
    static func wakeUpQueueTimer(_ queue: MainWakeUpQueue) -> any CEFPumpTimer {
        CEFWakeUpQueuePumpTimer(queue: queue)
    }

    /// Checks NSApp, asks the fork for its delayed work as absolute run times, then makes and starts the pump.
    /// - Parameters:
    ///   - shim: The in-process shim, before `CefInitialize` (no request comes before it).
    ///   - wakeUps: The main thread's deadline queue the timer arms on.
    ///   - gate: The runtime's gate for requests from Chromium threads (they find it through the callback context).
    ///   - makeTimer: Makes the pump's one timer (a test's counter).
    ///   - input: What the input policy reads and the app's input tap (feature `cefPumpInputPolicy`); nil never
    ///     holds a pass for input.
    ///   - crashKeys: The app's crash keys: each pass runs with Chromium's state at `inPump` (nil: none).
    ///   - windowPending: Whether a pane's browser is still being made (its first passes are start steps).
    /// - Throws: ``CEFRuntime/BootError/application`` when NSApp does not adopt CEF's application protocol;
    ///   nothing is made then.
    init(shim: CEFShimLibrary, wakeUps: MainWakeUpQueue, gate: RequestGate, makeTimer: MakeTimer,
         input: (seams: CEFPumpInputSeams, tap: InputEventTap)?, crashKeys: CrashKeySlots?, logger: Logger,
         windowPending: @escaping () -> Bool) throws(CEFRuntime.BootError) {
        // The app's NSApplication subclass must conform (CmuxApplication); the shim no longer patches NSApp.
        guard shim.prepareApplication() == 1 else { throw .application }
        let forkAPI = shim.forkAPIVersion()
        if forkAPI < CEFPumpSchedule.demandDrivenForkAPI {
            logger.error("CEF fork API \(forkAPI) predates the demand-driven pump (\(CEFPumpSchedule.demandDrivenForkAPI)): work left after a time slice and delayed tasks posted during a pass wait for the next CEF request, so pages may stall")
        }
        // CEF's delayed work as absolute run times with Chromium's leeway (p14-energy-046); older forks
        // keep the ms path.
        // SAFETY: the callback is a C function of `cmux_shim_schedule_delayed_fn`; its context is the runtime
        // `initialize` was given, which lives for the process once started.
        let absoluteRunTimes = unsafe shim.setScheduleDelayed(cefScheduleDelayedCallback) == 1
        logger.notice("CEF pump delayed work: \(absoluteRunTimes ? "absolute run times" : "whole milliseconds", privacy: .public)")
        let work = { CEFStartSteps.shared.pump(windowPending: windowPending()) { shim.doWork() } }
        pump = CEFMessagePump(work: work, timer: makeTimer(wakeUps), timeSlice: CEFPumpSchedule.timeSlice(forkAPI: forkAPI),
                              gate: gate, absoluteRunTimes: absoluteRunTimes, crashKeys: crashKeys)
        if let input {
            pump.setInputPolicy(CEFPumpInputPolicy(pending: input.seams.pending, dispatches: CEFPumpTapDispatches(tap: input.tap),
                                                   refreshInterval: input.seams.refreshInterval, frameTarget: input.seams.frameTarget))
        }
        pump.start()
    }

    /// The pump's counters (``Stats``).
    var stats: Stats { pump.stats }

    /// cmux changed Chromium state outside a CEF callback: a pass on the next run-loop turn.
    func scheduleNow() { pump.scheduleNow() }

    /// One pass now, with no timer (quit's drain after closing every browser).
    func drain() { pump.pumpNow() }

    /// No pass runs after this (`CefShutdown` may follow, or initialize failed).
    func stop() { pump.stop() }

    /// Starts the input policy's counters over (`debug.input` action `reset`).
    func resetInputCounters() { pump.resetInputCounters() }
}

/// Chromium's application protocols (base/message_loop/message_pump_apple.h,
/// include/cef_application_mac.h), declared under their Objective-C names.
/// The runtime keeps the first protocol registered under a name and remaps
/// later references to it, so the CEF shim's `@protocol(CefAppProtocol)` and
/// Chromium's `@protocol(CrAppProtocol)` resolve to these, and the app's
/// NSApplication (`CmuxApplication`) conforms statically: nothing is injected
/// at runtime. In process, Chromium must know when an event is being
/// dispatched through `sendEvent:` (nested run loops, menu tracking), and CEF
/// checks NSApp conforms before `CefInitialize` (``InProcessCEFBackend``).
@objc(CrAppProtocol) public protocol ChromiumAppProtocol: NSObjectProtocol {
    @objc(isHandlingSendEvent) func isHandlingSendEvent() -> Bool
}

@objc(CrAppControlProtocol) public protocol ChromiumAppControlProtocol: ChromiumAppProtocol {
    @objc(setHandlingSendEvent:) func setHandlingSendEvent(_ handlingSendEvent: Bool)
}

/// CEF's `CefAppProtocol`: what the in-process backend's NSApp check asks of NSApp.
@objc(CefAppProtocol) public protocol InProcessCEFApplication: ChromiumAppControlProtocol {}

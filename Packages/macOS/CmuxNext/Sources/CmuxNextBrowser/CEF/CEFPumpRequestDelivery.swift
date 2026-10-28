import CoreFoundation
import Foundation

/// C entry for `OnScheduleMessagePumpWork`. `ctx` is the `CEFRuntime`'s
/// ``CallbackRegistry`` token (``CEFRuntime/from(_:)``).
let cefScheduleCallback: CEFShimLibrary.ScheduleFn = { context, delayMilliseconds in
    // SAFETY: only the context's address is read; CEFRuntime.from and pumpGate(at:) turn it back.
    let address = unsafe UInt(bitPattern: context)
    CEFPumpRequestDelivery.deliver(
        address, admit: { gate, now in gate.admit(delayMilliseconds: delayMilliseconds, nowNanos: now) }
    ) { pump, fromChromiumThread in
        pump.request(milliseconds: delayMilliseconds, fromChromiumThread: fromChromiumThread)
    }
}

/// C entry for the fork's delayed work as absolute run times (`cmux_shim_schedule_delayed_fn`).
/// `ctx` is the runtime's token, as for ``cefScheduleCallback``.
let cefScheduleDelayedCallback: CEFShimLibrary.ScheduleDelayedFn = { context, runTimeNanos, leewayNanos, precise in
    let runTime = CEFPumpSchedule.runTimeNanos(runTimeNanos)
    // SAFETY: as for cefScheduleCallback.
    let address = unsafe UInt(bitPattern: context)
    CEFPumpRequestDelivery.deliver(address, admit: { gate, now in gate.admit(runTimeNanos: runTime, nowNanos: now) }) { pump, fromChromiumThread in
        pump.request(runTimeNanos: runTimeNanos, leewayNanos: leewayNanos, precise: precise != 0,
                     fromChromiumThread: fromChromiumThread)
    }
}

/// Hands a CEF schedule request to the pump on the main thread: at once on the main thread; from a
/// Chromium thread only when the gate admits it (`admit` gets the gate and the uptime in ns), as a
/// block on the main run loop. The seam between CEF's C callbacks and the main-actor pump.
nonisolated struct CEFPumpRequestDelivery {
    static func deliver(
        _ address: UInt,
        admit: (CEFPumpCrossThreadGate, UInt64) -> Bool,
        _ request: @escaping @MainActor @Sendable (CEFMessagePump, _ fromChromiumThread: Bool) -> Void
    ) {
        guard address != 0 else { return }
        let fromChromiumThread = !Thread.isMainThread
        if fromChromiumThread,
           let gate = CEFRuntime.pumpGate(at: address),
           !admit(gate, clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) {
            return // kept for the main thread's next pass or re-arm, with no wake (CEFPumpCrossThreadGate)
        }
        let deliver: @Sendable () -> Void = {
            // main-proof: deliver runs only in the Thread.isMainThread branch or as a CFRunLoopGetMain() block (below)
            MainActor.assumeIsolated {
                guard let pump = CEFRuntime.from(address)?.pump else { return }
                request(pump, fromChromiumThread)
            }
        }
        if Thread.isMainThread {
            deliver()
        } else {
            CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue, deliver)
            CFRunLoopWakeUp(CFRunLoopGetMain())
        }
    }
}

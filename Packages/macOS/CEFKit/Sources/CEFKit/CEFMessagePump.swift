import CCEF
import Foundation

/// Drives cef_do_message_loop_work on the main run loop. CEF requests pumps
/// via on_schedule_message_pump_work; a coarse repeating timer backstops any
/// missed schedule so the browser never stalls.
final class CEFMessagePump {
    static let shared = CEFMessagePump()

    private(set) var scheduledTimer: Timer?
    private(set) var backstopTimer: Timer?
    /// True while browsers are live or being created; only then does a
    /// standing 30 Hz backstop run (internal for @testable assertions).
    private(set) var backstopDemand = false
    private var isPumping = false

    init() {}

    func schedule(afterMilliseconds delayMs: Int64) {
        if Thread.isMainThread {
            scheduleOnMain(delayMs)
        } else {
            DispatchQueue.main.async { self.scheduleOnMain(delayMs) }
        }
    }

    /// Installs the backstop while browsers demand it and tears it down when
    /// the last browser closes, so an idle host pays no recurring
    /// main-thread wakeups. Schedule-driven one-shot pumps keep servicing
    /// CEF's own work requests either way.
    func setBackstopDemand(_ demand: Bool) {
        if Thread.isMainThread {
            applyBackstopDemand(demand)
        } else {
            DispatchQueue.main.async { self.applyBackstopDemand(demand) }
        }
    }

    func stop() {
        scheduledTimer?.invalidate()
        scheduledTimer = nil
        backstopTimer?.invalidate()
        backstopTimer = nil
    }

    private func applyBackstopDemand(_ demand: Bool) {
        backstopDemand = demand
        if demand {
            ensureBackstop()
        } else {
            backstopTimer?.invalidate()
            backstopTimer = nil
        }
    }

    private func scheduleOnMain(_ delayMs: Int64) {
        ensureBackstop()
        // Replacing the pending timer unconditionally IS the contract: the
        // header for on_schedule_message_pump_work says "any currently
        // pending scheduled call should be cancelled" — the newest request
        // is authoritative even when its deadline is later.
        scheduledTimer?.invalidate()
        // Never pump synchronously from inside a CEF callback; even a 0ms
        // request goes through the run loop.
        let timer = Timer(timeInterval: Double(max(delayMs, 0)) / 1000.0, repeats: false) { [weak self] _ in
            self?.pump()
        }
        timer.tolerance = 0
        RunLoop.main.add(timer, forMode: .common)
        scheduledTimer = timer
    }

    private func ensureBackstop() {
        guard backstopDemand, backstopTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.pump()
        }
        RunLoop.main.add(timer, forMode: .common)
        backstopTimer = timer
    }

    private func pump() {
        guard !isPumping, CEFApp.shared.isInitialized else { return }
        isPumping = true
        CEFRuntime.doMessageLoopWork()
        isPumping = false
    }
}

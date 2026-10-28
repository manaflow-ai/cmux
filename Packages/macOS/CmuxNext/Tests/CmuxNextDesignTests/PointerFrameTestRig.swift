import AppKit
import CmuxNextInput
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport

/// Windows' ``FrameInputCoalescer``s on a fake link whose frames come only when a test calls
/// ``frame()``, handed out by ``coalescers`` (p04-input-030's coalescer, for the overlay host, agent
/// cursor, thin scroller, hover reveal and hover card hover of p04-input-036). By default every window
/// shares ``coalescer``; `perWindow` gives each window its own, as the App's windows have.
@MainActor
final class PointerFrameTestRig {
    let scheduler: FrameScheduler
    /// The shared coalescer (every window's unless `perWindow`).
    let coalescer: FrameInputCoalescer
    let coalescers: FrameInputCoalescers
    private let made: Made
    private var frames = 0

    private final class Made {
        var byWindow: [ObjectIdentifier: FrameInputCoalescer] = [:]
    }

    init(perWindow: Bool = false) {
        let ledger = WakeupLedger()
        let scheduler = FrameScheduler.testing(clock: ManualClock(), ledger: ledger, mediaTime: { 1000 }) { _ in PointerFrameTestLink() }
        let coalescer = FrameInputCoalescer(scheduler: scheduler, clock: ManualClock(), ledger: ledger)
        let made = Made()
        self.scheduler = scheduler
        self.coalescer = coalescer
        self.made = made
        coalescers = FrameInputCoalescers { window in
            guard perWindow else { return coalescer }
            let key = ObjectIdentifier(window)
            if let own = made.byWindow[key] { return own }
            let own = FrameInputCoalescer(scheduler: scheduler, clock: ManualClock(), ledger: ledger)
            made.byWindow[key] = own
            return own
        }
    }

    /// `window`'s own coalescer (`perWindow`), made on its first post; nil before.
    func coalescer(of window: NSWindow) -> FrameInputCoalescer? { made.byWindow[ObjectIdentifier(window)] }

    /// One 120 Hz link frame: every coalescer's trailing deliveries run.
    func frame() {
        frames += 1
        scheduler.frameDidFire(timestamp: 1000 + Double(frames) / 120, refreshInterval: 1.0 / 120)
    }

    func close() {
        coalescer.invalidate()
        for own in made.byWindow.values { own.invalidate() }
    }
}

/// A window that carries hover frames (``HoverFrameInputHosting``), as the App's main windows do.
@MainActor
final class HoverFramesTestWindow: NSWindow, HoverFrameInputHosting {
    var hoverFrameInput: FrameInputCoalescers?

    /// A borderless window carrying `frames`, on screen when `visible`.
    static func make(_ frame: CGRect = CGRect(x: 200, y: 200, width: 400, height: 300), frames: FrameInputCoalescers?,
                     visible: Bool = true) -> HoverFramesTestWindow {
        _ = NSApplication.shared
        let window = HoverFramesTestWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.hoverFrameInput = frames
        if visible { window.orderFrontRegardless() }
        return window
    }
}

@MainActor
private final class PointerFrameTestLink: FrameLink {
    var isPaused = false
    func invalidate() {}
}

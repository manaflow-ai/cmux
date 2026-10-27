#if DEBUG || CMUX_BENCH_HOOKS
public import AppKit
import CmuxNextWakeups
import class CmuxSafeConcurrency.OnceContinuation
import enum CmuxSafeConcurrency.OnceContinuationError
import func CmuxSafeConcurrency.withOnceContinuation

extension TabStripDebug {
    /// `debug.new_tab {action: "frame_strip", gesture: "drag_new"}` (motion proofs): drags `strip`'s
    /// first tab right in 12 steps, one per frame (synthetic events into the strip's own handlers),
    /// and runs `midway` at step 4 (the app opens a terminal tab there: the drag's springs must keep
    /// running). False when the strip shows no tab.
    public static func dragFirstTab(in strip: TabStripView, midway: () -> Void) async -> Bool {
        guard let window = strip.window, let id = strip.displayedOrder.first, let start = strip.tabCenterInWindow(id) else { return false }
        func send(_ type: NSEvent.EventType, _ dx: CGFloat) {
            guard let event = NSEvent.mouseEvent(with: type, location: CGPoint(x: start.x + dx, y: start.y), modifierFlags: [],
                                                 timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                 context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)
            else { return }
            switch type {
            case .leftMouseDown: strip.mouseDown(with: event)
            case .leftMouseUp: strip.mouseUp(with: event)
            default: strip.mouseDragged(with: event)
            }
        }
        send(.leftMouseDown, 0)
        for step in 1...12 {
            let tick = DemandTimer(owner: "debug.frame_strip.drag")
            _ = try? await withOnceContinuation { (done: OnceContinuation<Void, OnceContinuationError>) in
                tick.scheduleOnMain(after: .milliseconds(16)) { done.resume(returning: ()) }
            }
            send(.leftMouseDragged, CGFloat(step) * 18)
            if step == 4 { midway() }
        }
        send(.leftMouseUp, 12 * 18)
        return true
    }
}
#endif

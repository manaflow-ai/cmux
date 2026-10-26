public import AppKit
public import CmuxNextWakeups

/// The app's presented-time estimate for input latency: CmuxNextWakeups' `PresentationClock` (p04-input-003).
extension PresentationClock: InputPresentationEstimating {
    public func holdLinkForInput(in window: NSWindow?) {
        if let window { holdForInput(window: window) } else { holdForInput(on: .app) }
    }

    public func presentedNanos(commitEndNanos: UInt64, in window: NSWindow?) -> UInt64 {
        if let window { return presented(commitEndNanos: commitEndNanos, window: window).nanos }
        return presented(commitEndNanos: commitEndNanos, on: .app).nanos
    }
}

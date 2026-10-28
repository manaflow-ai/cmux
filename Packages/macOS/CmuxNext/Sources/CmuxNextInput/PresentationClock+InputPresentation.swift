public import AppKit
public import CmuxNextWakeups

/// The app's presented-time estimate for input latency: CmuxNextWakeups' `PresentationClock`.
extension PresentationClock: InputPresentationEstimating {
    public func holdLinkForInput(in window: NSWindow?) {
        if let window { holdForInput(window: window) } else { holdForInput(on: .app) }
    }

    public func presented(committedAt nanos: UInt64, in window: NSWindow?, _ resolve: @escaping Resolve) {
        if let window { presented(commitEndNanos: nanos, window: window, resolve) } else {
            presented(commitEndNanos: nanos, on: .app, resolve)
        }
    }
}

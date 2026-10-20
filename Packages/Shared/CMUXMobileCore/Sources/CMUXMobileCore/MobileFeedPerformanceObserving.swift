/// Content-free Feed timing hooks, injected by the app composition root.
@MainActor
public protocol MobileFeedPerformanceObserving: AnyObject, Sendable {
    /// Whether a visible Feed should run its display-link sampler.
    var isSamplingEnabled: Bool { get }
    /// Updates visibility and the retained item count; hiding ends the window.
    func setVisible(_ visible: Bool, itemCount: Int)
    /// Marks actual scrolling, including deceleration, and resets callback timing.
    func setScrolling(_ scrolling: Bool)
    /// Records a display-link callback in monotonic seconds, not a rendered frame.
    func callback(at timestamp: Double, expectedInterval: Double)
    /// Records completed work, including scheduling/actor waits for async stages.
    func updateCompleted(stage: MobileFeedUpdateStage, startedAt: Double, endedAt: Double, itemCount: Int)
}

public import CmuxNextWakeups
public import Foundation

/// What the in-process pump's input policy (``CEFPumpInputPolicy``, feature `cefPumpInputPolicy`) reads
/// from the app: the app's one pending-input source, the one the main-thread budget yields to, and
/// the frame clock a hold is bounded by. `CEFEngine.init` takes it; nil keeps the pump as it was.
///
/// ```swift
/// CEFEngine(source: source, stores: stores, signInCallbacks: callbacks, input: inputTap,
///           pumpInput: features.isEnabled(.cefPumpInputPolicy) ? CEFPumpInputSeams(mainWork: mainWork) : nil)
/// ```
public struct CEFPumpInputSeams {
    /// Whether a person's input waits for the main thread.
    public let pending: any InputPendingSource
    /// The frame clock's refresh interval in seconds.
    public let refreshInterval: @MainActor () -> TimeInterval
    /// When the frame being made is shown, in seconds since boot; nil while no frame is made.
    public let frameTarget: @MainActor () -> TimeInterval?

    public init(pending: any InputPendingSource, refreshInterval: @escaping @MainActor () -> TimeInterval,
                frameTarget: @escaping @MainActor () -> TimeInterval?) {
        self.pending = pending
        self.refreshInterval = refreshInterval
        self.frameTarget = frameTarget
    }

    /// The app's: the main-thread budget's pending-input source and its frame scheduler's deadline.
    public init(mainWork: MainWorkScheduler) {
        let frames = mainWork.frames
        self.init(pending: mainWork.budget.pendingInput,
                  refreshInterval: { [weak frames] in frames?.refreshPeriod ?? 1.0 / 60 },
                  frameTarget: { [weak frames] in frames?.frameTarget })
    }
}

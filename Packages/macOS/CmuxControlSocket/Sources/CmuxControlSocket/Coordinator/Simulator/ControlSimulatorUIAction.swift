/// A semantic Simulator action driven by refs or named presets.
public enum ControlSimulatorUIAction: Sendable, Equatable {
    /// Leaves receipt time for worker startup, transport, and the final snapshot.
    public static let maximumEstimatedDurationMilliseconds: Int64 = 120_000

    /// Taps one current element reference.
    case tap(
        elementRef: String,
        preDelayMilliseconds: Int,
        postDelayMilliseconds: Int
    )
    /// Sends explicit touch phases to one current element reference.
    case touch(
        elementRef: String,
        down: Bool,
        up: Bool,
        delayMilliseconds: Int
    )
    /// Swipes within one current element reference.
    case swipe(
        elementRef: String,
        direction: String,
        durationMilliseconds: Int,
        distance: Double,
        steps: Int,
        preDelayMilliseconds: Int,
        postDelayMilliseconds: Int
    )
    /// Drags from one current element reference.
    case drag(
        elementRef: String,
        direction: String,
        durationMilliseconds: Int,
        distance: Double,
        steps: Int,
        preDelayMilliseconds: Int,
        postDelayMilliseconds: Int
    )
    /// Holds a touch on one current element reference.
    case longPress(elementRef: String, durationMilliseconds: Int)
    /// Focuses one current element reference and types text.
    case typeText(elementRef: String, text: String, replaceExisting: Bool)
    /// Presses one USB HID key usage.
    case keyPress(keyCode: UInt32, durationMilliseconds: Int)
    /// Presses a bounded sequence of USB HID key usages.
    case keySequence(keyCodes: [UInt32], delayMilliseconds: Int)
    /// Presses or holds one Simulator hardware button.
    case button(button: String, durationMilliseconds: Int?)
    /// Performs one named screen-level gesture.
    case gesturePreset(
        preset: String,
        durationMilliseconds: Int,
        distance: Double,
        steps: Int,
        preDelayMilliseconds: Int,
        postDelayMilliseconds: Int
    )
    /// Performs a bounded sequence of taps resolved from one snapshot.
    case batch(steps: [ControlSimulatorUITapStep])

    /// A conservative bound for declared delays and known internal pacing.
    public var estimatedDurationMilliseconds: Int64 {
        let snapshotCaptureBudget: Int64 = 2_500
        let finalSnapshotBudget: Int64 = 2_500
        let tapPacing: Int64 = 50
        switch self {
        case let .tap(_, preDelay, postDelay):
            return snapshotCaptureBudget + Int64(preDelay) + tapPacing
                + Int64(postDelay) + finalSnapshotBudget
        case let .touch(_, _, _, delay):
            return snapshotCaptureBudget + Int64(delay) + finalSnapshotBudget
        case let .swipe(_, _, duration, _, _, preDelay, postDelay),
             let .drag(_, _, duration, _, _, preDelay, postDelay):
            return snapshotCaptureBudget + Int64(preDelay) + Int64(duration)
                + Int64(postDelay) + finalSnapshotBudget
        case let .longPress(_, duration):
            return snapshotCaptureBudget + Int64(duration) + finalSnapshotBudget
        case let .typeText(_, text, _):
            let maximumTextPacing = Int64(text.utf8.count) * 20
            return snapshotCaptureBudget + maximumTextPacing + finalSnapshotBudget
        case let .keyPress(_, duration):
            return Int64(duration) + finalSnapshotBudget
        case let .keySequence(keyCodes, delay):
            let pressPacing = Int64(keyCodes.count) * 50
            let interKeyPacing = Int64(max(0, keyCodes.count - 1)) * Int64(delay)
            return pressPacing + interKeyPacing + finalSnapshotBudget
        case let .button(_, duration):
            return Int64(duration ?? 50) + 750 + finalSnapshotBudget
        case let .gesturePreset(_, duration, _, _, preDelay, postDelay):
            return Int64(preDelay) + Int64(duration) + Int64(postDelay)
                + finalSnapshotBudget
        case let .batch(steps):
            let actionBudget = steps.reduce(Int64.zero) { partial, step in
                partial + snapshotCaptureBudget + Int64(step.preDelayMilliseconds)
                    + tapPacing + Int64(step.postDelayMilliseconds)
            }
            return actionBudget + finalSnapshotBudget
        }
    }

    /// Whether the action can finish before the server's receipt deadline.
    public var fitsReceiptDeadline: Bool {
        estimatedDurationMilliseconds <= Self.maximumEstimatedDurationMilliseconds
    }
}

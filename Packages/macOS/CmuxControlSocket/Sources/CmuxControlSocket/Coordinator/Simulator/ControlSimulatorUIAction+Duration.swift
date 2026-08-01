extension ControlSimulatorUIAction {
    /// A conservative bound for declared delays and known internal pacing.
    public var estimatedDurationMilliseconds: Int64 {
        let snapshotCaptureBudget: Int64 = 2_500
        let finalSnapshotBudget: Int64 = 2_500
        let accessibilityQuiescenceBudget: Int64 = 750
        let tapPacing: Int64 = 50
        switch self {
        case let .tap(_, preDelay, postDelay):
            return snapshotCaptureBudget + Int64(preDelay) + tapPacing
                + max(Int64(postDelay), accessibilityQuiescenceBudget)
                + finalSnapshotBudget
        case let .touch(_, _, up, delay):
            return snapshotCaptureBudget + Int64(delay)
                + (up ? accessibilityQuiescenceBudget : 0)
                + finalSnapshotBudget
        case let .swipe(_, _, duration, _, _, preDelay, postDelay),
             let .drag(_, _, duration, _, _, preDelay, postDelay):
            return snapshotCaptureBudget + Int64(preDelay) + Int64(duration)
                + max(Int64(postDelay), accessibilityQuiescenceBudget)
                + finalSnapshotBudget
        case let .longPress(_, duration):
            return snapshotCaptureBudget + Int64(duration)
                + accessibilityQuiescenceBudget + finalSnapshotBudget
        case let .typeText(_, text, _):
            let maximumTextPacing = Int64(text.utf8.count) * 20
            return snapshotCaptureBudget + accessibilityQuiescenceBudget
                + maximumTextPacing + accessibilityQuiescenceBudget
                + finalSnapshotBudget
        case let .keyPress(_, duration):
            return Int64(duration) + accessibilityQuiescenceBudget
                + finalSnapshotBudget
        case let .keySequence(keyCodes, delay):
            let pressPacing = Int64(keyCodes.count) * 50
            let interKeyPacing = Int64(max(0, keyCodes.count - 1)) * Int64(delay)
            return pressPacing + interKeyPacing + accessibilityQuiescenceBudget
                + finalSnapshotBudget
        case let .button(_, duration):
            return Int64(duration ?? 50) + 750 + finalSnapshotBudget
        case let .gesturePreset(_, duration, _, _, preDelay, postDelay):
            return Int64(preDelay) + Int64(duration)
                + max(Int64(postDelay), accessibilityQuiescenceBudget)
                + finalSnapshotBudget
        case let .batch(steps):
            let actionBudget = steps.reduce(Int64.zero) { partial, step in
                partial + snapshotCaptureBudget + Int64(step.preDelayMilliseconds)
                    + tapPacing + max(
                        Int64(step.postDelayMilliseconds),
                        accessibilityQuiescenceBudget
                    )
            }
            return actionBudget + finalSnapshotBudget
        }
    }

    /// Whether the action can finish before the server's receipt deadline.
    public var fitsReceiptDeadline: Bool {
        estimatedDurationMilliseconds <= Self.maximumEstimatedDurationMilliseconds
    }
}

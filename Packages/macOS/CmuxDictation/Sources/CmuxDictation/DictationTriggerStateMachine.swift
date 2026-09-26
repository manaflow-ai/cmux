import Foundation

/// A dictation shortcut event produced by ``DictationTriggerStateMachine``.
///
/// The semantics mirror push-to-talk and sticky-toggle dictation:
/// - ``doubleTap``: two bare-fn presses within the double-tap interval. Toggles
///   a sticky session (start, or finish the one already listening).
/// - ``holdStart``: a bare-fn press held past the hold threshold. Starts a
///   push-to-talk session while the key remains down.
/// - ``holdEnd``: the key from ``holdStart`` was released. Finishes the session
///   so the transcript finalizes and inserts.
public enum DictationTrigger: Equatable, Sendable {
    /// Two bare-fn presses within ``DictationShortcutConfiguration/doubleTapInterval``.
    case doubleTap
    /// A bare-fn press held past ``DictationShortcutConfiguration/holdThreshold``.
    case holdStart
    /// Release of the press that produced ``holdStart``.
    case holdEnd
}

/// Tuning constants and pure classification input for the fn-key trigger.
///
/// All values are seconds measured on a monotonic timeline (the monitor passes
/// `ProcessInfo.systemUptime`-style timestamps; tests pass their own).
public struct DictationShortcutConfiguration: Equatable, Sendable {
    /// Maximum spacing between two presses that still counts as a double tap.
    /// Gemini for Mac uses a similar window; 0.45 s matches common
    /// double-tap detection without firing on deliberate single taps.
    public var doubleTapInterval: Double

    /// How long the key must stay down before a hold is reported.
    public var holdThreshold: Double

    /// Builds a configuration with the v1 defaults.
    ///
    /// - Parameters:
    ///   - doubleTapInterval: Double-tap window in seconds.
    ///   - holdThreshold: Hold-activation delay in seconds.
    public init(doubleTapInterval: Double = 0.45, holdThreshold: Double = 0.8) {
        self.doubleTapInterval = doubleTapInterval
        self.holdThreshold = holdThreshold
    }
}

/// Pure fn-key trigger classifier.
///
/// The monitor feeds every bare-fn transition into ``handle``; the machine
/// decides when the tap/hold gestures produce ``DictationTrigger`` values.
/// Deliberately free of AppKit and clocks so tests drive synthetic timelines.
///
/// Transition model:
/// - Press inside the double-tap window after the previous press →
///   ``DictationTrigger/doubleTap`` (hold detection is suppressed for that press).
/// - Press held past ``DictationShortcutConfiguration/holdThreshold`` → the
///   monitor reports ``DictationTrigger/holdStart`` itself (time-based, no event
///   needed); the machine then pairs the release with ``DictationTrigger/holdEnd``.
/// - Any press with other modifier keys down is ignored (and cancels a pending
///   single-tap window) so ⌥fn or ⇧fn never triggers dictation.
public struct DictationTriggerStateMachine: Sendable {
    private let configuration: DictationShortcutConfiguration

    /// Timestamp of the previous press when it is still inside the double-tap
    /// window; `nil` when there is no pending single tap.
    private var previousPressAt: Double?

    /// Timestamp of the current press; non-nil while the key is down.
    private var currentPressAt: Double?

    /// Whether the current press already produced a hold pair.
    private var holdIsActive: Bool

    /// Whether the current press was consumed as a double tap (release is inert).
    private var doubleTapConsumed: Bool

    /// Builds a machine with the given configuration.
    ///
    /// - Parameter configuration: Gesture timing constants.
    public init(configuration: DictationShortcutConfiguration = DictationShortcutConfiguration()) {
        self.configuration = configuration
        self.previousPressAt = nil
        self.currentPressAt = nil
        self.holdIsActive = false
        self.doubleTapConsumed = false
    }

    /// Whether the tracked press is still down (used by the monitor's hold timer).
    public var isPressActive: Bool { currentPressAt != nil }

    /// Timestamp of the press being tracked for a hold, when one is down.
    public var activePressStartedAt: Double? { currentPressAt }

    /// Whether the active press has already emitted ``DictationTrigger/holdStart``.
    public var isHoldActive: Bool { holdIsActive }

    /// Feeds one fn-key transition.
    ///
    /// - Parameters:
    ///   - isDown: `true` for key-down, `false` for key-up.
    ///   - isBareFunction: `true` when the event's only modifier is fn.
    ///   - at: Monotonic timestamp of the transition.
    /// - Returns: The trigger this transition completes, if any.
    public mutating func handle(isDown: Bool, isBareFunction: Bool, timestamp: Double) -> DictationTrigger? {
        guard isBareFunction else {
            // Modified press (⇧fn, ⌥fn …): never triggers, and breaks any
            // pending double-tap window so a tap-⇧-tap never pairs.
            if isDown {
                previousPressAt = nil
            }
            return nil
        }

        if isDown {
            return handlePress(timestamp: timestamp)
        } else {
            return handleRelease(timestamp: timestamp)
        }
    }

    /// Reports that the hold threshold elapsed while the tracked press is down.
    /// Call after the monitor's timer fires; pairs with ``DictationTrigger/holdEnd``
    /// on release. Returns `false` when there is no press to promote (already
    /// released, or consumed as a double tap).
    @discardableResult
    public mutating func beginHold() -> Bool {
        guard currentPressAt != nil, !doubleTapConsumed, !holdIsActive else { return false }
        holdIsActive = true
        return true
    }

    /// Forgets any pending double-tap window. Used when the press produced an
    /// unrelated action so a later lone tap does not pair with stale state.
    public mutating func clearPendingDoubleTap() {
        previousPressAt = nil
    }

    private mutating func handlePress(timestamp: Double) -> DictationTrigger? {
        if let previous = previousPressAt, timestamp - previous <= configuration.doubleTapInterval {
            // Second press inside the window: sticky-toggle double tap. The
            // release is inert and hold detection is suppressed for this press.
            previousPressAt = nil
            currentPressAt = timestamp
            doubleTapConsumed = true
            holdIsActive = false
            return .doubleTap
        }
        previousPressAt = timestamp
        currentPressAt = timestamp
        doubleTapConsumed = false
        holdIsActive = false
        return nil
    }

    private mutating func handleRelease(timestamp: Double) -> DictationTrigger? {
        guard currentPressAt != nil else { return nil }
        currentPressAt = nil
        if holdIsActive {
            holdIsActive = false
            doubleTapConsumed = false
            return .holdEnd
        }
        // Plain tap or double-tap second press release: nothing to emit.
        return nil
    }
}

/// Which part of a scroll a timed scroll event is (``ScrollFrameTiming``, the `phase=` of
/// ``SignpostName/scrollToFrame``).
public nonisolated enum ScrollFramePhase: String, Sendable, Hashable, CaseIterable {
    /// A trackpad touch before any movement (`mayBegin`).
    case touch
    /// The first movement of a trackpad gesture (`began`).
    case began
    /// A movement of a trackpad gesture (`changed`).
    case changed
    /// The fingers lifted or the gesture was cancelled (`ended`, `cancelled`).
    case ended
    /// The coast after a flick (an event with a momentum phase).
    case momentum
    /// A mouse-wheel notch (no phase and no momentum).
    case wheel
}

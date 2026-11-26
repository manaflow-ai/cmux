import CMUXMobileCore

/// Reduces native tracking and deceleration callbacks into browser scroll phases.
struct BrowserStreamScrollPhasePolicy: Equatable, Sendable {
    /// Native scroll lifecycle inputs.
    enum Event: Equatable, Sendable {
        /// Direct touch tracking began.
        case trackingBegan
        /// Direct touch tracking changed.
        case trackingChanged
        /// Direct touch tracking ended and may continue decelerating.
        case trackingEnded(willDecelerate: Bool)
        /// Momentum began.
        case momentumBegan
        /// Momentum changed.
        case momentumChanged
        /// Momentum ended.
        case momentumEnded
        /// The gesture was cancelled.
        case cancelled
    }

    private enum State: Equatable, Sendable { case idle, tracking, momentum }
    private var state: State = .idle

    /// Creates an idle phase reducer.
    init() {}

    /// Applies a native lifecycle event and returns the wire phase to emit.
    /// - Parameter event: The native scroll lifecycle event.
    /// - Returns: The matching browser wire phase, or `nil` when no event should be sent.
    mutating func consume(_ event: Event) -> MobileBrowserScrollPhase? {
        switch event {
        case .trackingBegan:
            state = .tracking
            return .began
        case .trackingChanged:
            if state == .idle { state = .tracking; return .began }
            return .changed
        case let .trackingEnded(willDecelerate):
            state = willDecelerate ? .momentum : .idle
            return .ended
        case .momentumBegan:
            state = .momentum
            return .momentumBegan
        case .momentumChanged:
            if state != .momentum { state = .momentum; return .momentumBegan }
            return .momentumChanged
        case .momentumEnded:
            state = .idle
            return .momentumEnded
        case .cancelled:
            state = .idle
            return .cancelled
        }
    }
}

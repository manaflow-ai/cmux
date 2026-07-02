import CoreGraphics

struct SidebarRowSwipeGestureModel {
    struct Configuration: Equatable, Sendable {
        let maxRevealDistance: CGFloat
        let commitThreshold: CGFloat
        let rubberBandDamping: CGFloat
        let rubberBandExtraLimitFraction: CGFloat

        init(
            maxRevealDistance: CGFloat = 96,
            commitThreshold: CGFloat = 64,
            rubberBandDamping: CGFloat = 0.25,
            rubberBandExtraLimitFraction: CGFloat = 0.35
        ) {
            self.maxRevealDistance = maxRevealDistance
            self.commitThreshold = commitThreshold
            self.rubberBandDamping = rubberBandDamping
            self.rubberBandExtraLimitFraction = rubberBandExtraLimitFraction
        }
    }

    enum Phase: Equatable, Sendable {
        case began
        case changed
        case ended
        case cancelled
        case momentum
    }

    enum Action: Equatable, Sendable {
        case leading
        case trailing
    }

    struct Event: Equatable, Sendable {
        let phase: Phase
        let scrollingDeltaX: CGFloat
        let scrollingDeltaY: CGFloat

        init(phase: Phase, scrollingDeltaX: CGFloat, scrollingDeltaY: CGFloat) {
            self.phase = phase
            self.scrollingDeltaX = scrollingDeltaX
            self.scrollingDeltaY = scrollingDeltaY
        }
    }

    struct Result: Equatable, Sendable {
        let claimed: Bool
        let offset: CGFloat
        let commit: Action?
        let shouldAnimateOffset: Bool
    }

    private enum GestureState: Equatable, Sendable {
        case idle
        case pending(accumulatedDeltaX: CGFloat, accumulatedDeltaY: CGFloat)
        case tracking(direction: Action, accumulatedOffset: CGFloat)
        case ignoringUntilEnd
        case suppressingMomentum
    }

    private let configuration: Configuration
    private var state: GestureState = .idle

    init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    mutating func handle(_ event: Event) -> Result {
        switch event.phase {
        case .began:
            return begin(event)
        case .changed:
            return change(event)
        case .ended:
            return end(event)
        case .cancelled:
            return cancel()
        case .momentum:
            return momentum()
        }
    }

    private mutating func begin(_ event: Event) -> Result {
        state = .pending(accumulatedDeltaX: 0, accumulatedDeltaY: 0)
        return updatePending(with: event)
    }

    private mutating func change(_ event: Event) -> Result {
        if case .pending = state {
            return updatePending(with: event)
        }

        guard case let .tracking(direction, accumulatedOffset) = state else {
            return Result(
                claimed: state == .suppressingMomentum,
                offset: 0,
                commit: nil,
                shouldAnimateOffset: false
            )
        }

        let nextOffset = constrainedOffset(accumulatedOffset + normalized(event.scrollingDeltaX), direction: direction)
        state = .tracking(direction: direction, accumulatedOffset: nextOffset)
        return Result(
            claimed: true,
            offset: visibleOffset(for: nextOffset),
            commit: nil,
            shouldAnimateOffset: false
        )
    }

    private mutating func end(_ event: Event) -> Result {
        guard case let .tracking(direction, accumulatedOffset) = state else {
            if state == .ignoringUntilEnd || isPending {
                state = .idle
            }
            return Result(
                claimed: state == .suppressingMomentum,
                offset: 0,
                commit: nil,
                shouldAnimateOffset: false
            )
        }

        let finalOffset = constrainedOffset(accumulatedOffset + normalized(event.scrollingDeltaX), direction: direction)
        let commit = abs(visibleOffset(for: finalOffset)) > configuration.commitThreshold ? direction : nil
        state = .suppressingMomentum
        return Result(claimed: true, offset: 0, commit: commit, shouldAnimateOffset: true)
    }

    private mutating func cancel() -> Result {
        guard case .tracking = state else {
            if state == .ignoringUntilEnd || isPending {
                state = .idle
            }
            return Result(
                claimed: state == .suppressingMomentum,
                offset: 0,
                commit: nil,
                shouldAnimateOffset: false
            )
        }

        state = .suppressingMomentum
        return Result(claimed: true, offset: 0, commit: nil, shouldAnimateOffset: true)
    }

    private mutating func momentum() -> Result {
        switch state {
        case .suppressingMomentum:
            return Result(claimed: true, offset: 0, commit: nil, shouldAnimateOffset: false)
        case .tracking:
            state = .suppressingMomentum
            return Result(claimed: true, offset: 0, commit: nil, shouldAnimateOffset: true)
        case .pending:
            state = .idle
            return Result(claimed: false, offset: 0, commit: nil, shouldAnimateOffset: false)
        case .ignoringUntilEnd, .idle:
            return Result(claimed: false, offset: 0, commit: nil, shouldAnimateOffset: false)
        }
    }

    private mutating func updatePending(with event: Event) -> Result {
        guard case let .pending(accumulatedDeltaX, accumulatedDeltaY) = state else {
            return Result(claimed: false, offset: 0, commit: nil, shouldAnimateOffset: false)
        }

        let nextDeltaX = accumulatedDeltaX + normalized(event.scrollingDeltaX)
        let nextDeltaY = accumulatedDeltaY + normalized(event.scrollingDeltaY)
        guard abs(nextDeltaX) + abs(nextDeltaY) > 0 else {
            state = .pending(accumulatedDeltaX: nextDeltaX, accumulatedDeltaY: nextDeltaY)
            return Result(claimed: false, offset: 0, commit: nil, shouldAnimateOffset: false)
        }
        guard abs(nextDeltaX) > abs(nextDeltaY), nextDeltaX != 0 else {
            state = .ignoringUntilEnd
            return Result(claimed: false, offset: 0, commit: nil, shouldAnimateOffset: false)
        }

        let direction: Action = nextDeltaX > 0 ? .leading : .trailing
        let accumulatedOffset = constrainedOffset(nextDeltaX, direction: direction)
        state = .tracking(direction: direction, accumulatedOffset: accumulatedOffset)
        return Result(
            claimed: true,
            offset: visibleOffset(for: accumulatedOffset),
            commit: nil,
            shouldAnimateOffset: false
        )
    }

    private var isPending: Bool {
        if case .pending = state { return true }
        return false
    }

    private func normalized(_ delta: CGFloat) -> CGFloat {
        delta.isFinite ? delta : 0
    }

    private func constrainedOffset(_ offset: CGFloat, direction: Action) -> CGFloat {
        switch direction {
        case .leading:
            return max(0, offset)
        case .trailing:
            return min(0, offset)
        }
    }

    private func visibleOffset(for accumulatedOffset: CGFloat) -> CGFloat {
        let sign: CGFloat = accumulatedOffset >= 0 ? 1 : -1
        return sign * rubberBandedDistance(abs(accumulatedOffset))
    }

    private func rubberBandedDistance(_ distance: CGFloat) -> CGFloat {
        guard distance > configuration.maxRevealDistance else { return distance }
        let extra = distance - configuration.maxRevealDistance
        let cappedExtra = min(
            extra * configuration.rubberBandDamping,
            configuration.maxRevealDistance * configuration.rubberBandExtraLimitFraction
        )
        return configuration.maxRevealDistance + cappedExtra
    }
}

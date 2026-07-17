/// Owns the durable follow-tail state entered by an artifact End jump.
struct ChatArtifactTextBottomPinStateMachine: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case initialAnimation
        case following
    }

    enum Action: Equatable, Sendable {
        case none
        case scrollToBottom(
            boundary: ChatArtifactTextBottomBoundary,
            animated: Bool
        )
    }

    private(set) var target: ChatArtifactTextEndJumpTarget?
    private(set) var phase: Phase?
    private(set) var visibleBoundary: ChatArtifactTextBottomBoundary?
    private var requestedBoundary: ChatArtifactTextBottomBoundary?

    var isPinned: Bool {
        target != nil
    }

    mutating func engage(
        target: ChatArtifactTextEndJumpTarget,
        boundary: ChatArtifactTextBottomBoundary
    ) -> Action {
        self.target = target
        phase = .initialAnimation
        visibleBoundary = nil
        requestedBoundary = boundary
        return .scrollToBottom(boundary: boundary, animated: true)
    }

    mutating func initialAnimationSettled(
        at boundary: ChatArtifactTextBottomBoundary
    ) -> Action {
        guard isPinned else { return .none }
        phase = .following
        visibleBoundary = nil
        requestedBoundary = boundary
        return .scrollToBottom(boundary: boundary, animated: false)
    }

    mutating func layoutChanged(
        to boundary: ChatArtifactTextBottomBoundary
    ) -> Action {
        guard phase == .following,
              requestedBoundary != boundary else { return .none }
        visibleBoundary = nil
        requestedBoundary = boundary
        return .scrollToBottom(boundary: boundary, animated: false)
    }

    mutating func appendsFlushed(
        at boundary: ChatArtifactTextBottomBoundary
    ) -> Action {
        guard phase == .following else { return .none }
        visibleBoundary = nil
        requestedBoundary = boundary
        return .scrollToBottom(boundary: boundary, animated: false)
    }

    mutating func reachedEOF(
        at boundary: ChatArtifactTextBottomBoundary
    ) -> Action {
        guard markReachedEOF() else { return .none }
        guard phase == .following else { return .none }
        visibleBoundary = nil
        requestedBoundary = boundary
        return .scrollToBottom(boundary: boundary, animated: false)
    }

    @discardableResult
    mutating func markReachedEOF() -> Bool {
        guard target == .latest else { return false }
        target = .end
        return true
    }

    mutating func didApplyPin(at boundary: ChatArtifactTextBottomBoundary) {
        guard phase == .following else { return }
        visibleBoundary = boundary
        requestedBoundary = boundary
    }

    mutating func userInteracted() {
        target = nil
        phase = nil
        visibleBoundary = nil
        requestedBoundary = nil
    }
}

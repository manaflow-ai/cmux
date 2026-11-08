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
        at boundary: ChatArtifactTextBottomBoundary,
        isBoundaryVisible: Bool = false
    ) -> Action {
        guard isPinned else { return .none }
        let targetBoundary = latestBoundary(
            requestedBoundary,
            or: boundary
        )
        requestedBoundary = targetBoundary
        guard isBoundaryVisible, targetBoundary == boundary else {
            visibleBoundary = nil
            return .scrollToBottom(boundary: targetBoundary, animated: false)
        }
        phase = .following
        visibleBoundary = boundary
        requestedBoundary = boundary
        return .none
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
        guard isPinned else { return .none }
        guard phase == .following else {
            visibleBoundary = nil
            requestedBoundary = boundary
            return .scrollToBottom(boundary: boundary, animated: true)
        }
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
        guard isPinned, requestedBoundary == boundary else { return }
        phase = .following
        visibleBoundary = boundary
        requestedBoundary = boundary
    }

    mutating func userInteracted() {
        target = nil
        phase = nil
        visibleBoundary = nil
        requestedBoundary = nil
    }

    private func latestBoundary(
        _ first: ChatArtifactTextBottomBoundary?,
        or second: ChatArtifactTextBottomBoundary
    ) -> ChatArtifactTextBottomBoundary {
        guard let first else { return second }
        if first.storageEnd != second.storageEnd {
            return first.storageEnd > second.storageEnd ? first : second
        }
        return first.contentOffsetY > second.contentOffsetY ? first : second
    }
}

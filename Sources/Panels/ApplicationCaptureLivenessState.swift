import Foundation

struct ApplicationCaptureLivenessState {
    let startedAt: TimeInterval
    private(set) var firstFrameAt: TimeInterval?

    mutating func recordFrame(at timestamp: TimeInterval) {
        if firstFrameAt == nil {
            firstFrameAt = timestamp
        }
    }

    var hasPresentedFrame: Bool { firstFrameAt != nil }

    func failure(
        at timestamp: TimeInterval,
        firstFrameTimeout: TimeInterval
    ) -> ApplicationCaptureLivenessFailure? {
        guard firstFrameAt == nil else { return nil }
        return timestamp - startedAt >= firstFrameTimeout
            ? .firstFrameTimedOut
            : nil
    }
}

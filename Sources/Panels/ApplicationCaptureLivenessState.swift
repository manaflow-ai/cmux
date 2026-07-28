import Foundation

struct ApplicationCaptureLivenessState {
    let startedAt: TimeInterval
    private(set) var lastFrameAt: TimeInterval?

    mutating func recordFrame(at timestamp: TimeInterval) {
        lastFrameAt = timestamp
    }

    func failure(
        at timestamp: TimeInterval,
        firstFrameTimeout: TimeInterval,
        frameStallTimeout: TimeInterval
    ) -> ApplicationCaptureLivenessFailure? {
        if let lastFrameAt {
            return timestamp - lastFrameAt >= frameStallTimeout
                ? .frameStalled
                : nil
        }
        return timestamp - startedAt >= firstFrameTimeout
            ? .firstFrameTimedOut
            : nil
    }
}

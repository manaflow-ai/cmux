import CmuxLink
import os

/// The state fan-out shared by both media backings.
final class MediaTrackStates: Sendable {
    private struct State {
        var current: MediaTrackState = .live
        var continuations: [AsyncStream<MediaTrackState>.Continuation] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var current: MediaTrackState { state.withLock { $0.current } }

    func stream() -> AsyncStream<MediaTrackState> {
        let (stream, continuation) = AsyncStream.makeStream(of: MediaTrackState.self, bufferingPolicy: .bufferingNewest(4))
        let ended = state.withLock { state -> Bool in
            continuation.yield(state.current)
            guard state.current != .ended else { return true }
            state.continuations.append(continuation)
            return false
        }
        if ended { continuation.finish() }
        return stream
    }

    /// Ends the track; returns false when it had already ended.
    @discardableResult
    func end() -> Bool {
        let continuations = state.withLock { state -> [AsyncStream<MediaTrackState>.Continuation]? in
            guard state.current != .ended else { return nil }
            state.current = .ended
            defer { state.continuations = [] }
            return state.continuations
        }
        guard let continuations else { return false }
        for continuation in continuations {
            continuation.yield(.ended)
            continuation.finish()
        }
        return true
    }
}

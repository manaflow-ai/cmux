import CmuxLink
import os

/// A send-rate limit (the conformance throttle hook): each frame waits for
/// its transmit time on the clock, like a link of that rate.
final class SendPacer: Sendable {
    private struct State {
        var bytesPerSecond: Int?
        var freeAt: Duration = .zero
    }

    // carve-out: one arithmetic update per send, never held across an await.
    private let state: OSAllocatedUnfairLock<State>
    private let clock: LinkClock

    init(bytesPerSecond: Int?, clock: LinkClock) {
        // carve-out: see above.
        state = OSAllocatedUnfairLock(initialState: State(bytesPerSecond: bytesPerSecond))
        self.clock = clock
    }

    func setRate(_ bytesPerSecond: Int?) {
        state.withLock { $0.bytesPerSecond = bytesPerSecond }
    }

    func pace(_ bytes: Int) async throws {
        let now = clock.now
        let wait = state.withLock { state -> Duration in
            guard let rate = state.bytesPerSecond, rate > 0 else { return .zero }
            let start = max(now, state.freeAt)
            state.freeAt = start + .seconds(Double(bytes) / Double(rate))
            return state.freeAt - now
        }
        if wait > .zero { try await clock.sleep(for: wait) }
    }
}

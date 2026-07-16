/// Coalesces streamed text chunks while scrolling must remain uninterrupted.
struct ChatArtifactTextAppendPolicy: Equatable, Sendable {
    private enum DeferralState: Equatable, Sendable {
        case idle
        case tracking
        case decelerating
        case programmaticAnimation
    }

    private var state = DeferralState.idle
    private var pendingChunkCount = 0

    var isDeferring: Bool {
        state != .idle
    }

    mutating func enqueue(chunkCount: Int) -> Int {
        guard chunkCount > 0 else { return 0 }
        pendingChunkCount += chunkCount
        return state == .idle ? drain() : 0
    }

    mutating func beginTracking() {
        state = .tracking
    }

    mutating func endTracking(willDecelerate: Bool) -> Int {
        state = willDecelerate ? .decelerating : .idle
        return state == .idle ? drain() : 0
    }

    mutating func endDecelerating() -> Int {
        state = .idle
        return drain()
    }

    mutating func beginProgrammaticAnimation() {
        state = .programmaticAnimation
    }

    mutating func endProgrammaticAnimation() -> Int {
        guard state == .programmaticAnimation else { return 0 }
        state = .idle
        return drain()
    }

    mutating func reset() {
        state = .idle
        pendingChunkCount = 0
    }

    private mutating func drain() -> Int {
        defer { pendingChunkCount = 0 }
        return pendingChunkCount
    }
}

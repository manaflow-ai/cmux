/// Pure lifecycle reducer for one Ghostty-backed terminal surface.
///
/// The reducer separates queueing a render from executing it, tracks the
/// current surface generation, preserves the last usable presentation through
/// reconnect/rebuild, and bounds replay-based recovery. It owns no UIKit or
/// Ghostty objects; callers perform side effects based on the returned
/// decisions.
public struct TerminalSurfaceSessionState: Equatable, Sendable {
    /// Backwards-compatible nested spelling for render phases.
    public typealias RenderPhase = TerminalSurfaceRenderPhase
    /// Backwards-compatible nested spelling for replay retry state.
    public typealias ReplayRecovery = TerminalSurfaceReplayRecovery

    /// Monotonically increasing generation used to reject stale render/output completions.
    public private(set) var generation: UInt64 = 0
    /// Current render phase for the active generation.
    public private(set) var renderPhase: RenderPhase = .idle
    /// Whether the current generation has rendered at least one live frame.
    public private(set) var hasLiveFrame = false
    /// Whether a previous live frame is being preserved while a rebuilt generation waits for output.
    public private(set) var hasPreservedFrame = false
    /// Whether output has reached the current generation since it was mounted.
    public private(set) var hasAppliedOutputInGeneration = false
    /// Whether a text snapshot fallback is available.
    public private(set) var hasSnapshot = false
    /// Whether a surface generation is currently mounted.
    public private(set) var isMounted = false
    /// Whether transport reconnect UI should be reflected in presentation.
    public private(set) var isConnectionRecovering = false
    /// Whether renders are blocked until replay or live output reaches the rebuilt generation.
    public private(set) var renderBlockedUntilOutput = false
    /// Number of automatic surface rebuilds consumed in this mounted session.
    public private(set) var automaticRebuilds = 0
    /// Replay retry state for a rebuilt generation waiting for authoritative output.
    public private(set) var replayRecovery: ReplayRecovery?
    /// Maximum automatic surface rebuilds allowed before failing closed.
    public let maxAutomaticRebuilds: Int
    /// Maximum replay attempts for a rebuilt generation before failing closed.
    public let maxReplayAttempts: Int

    /// Creates a terminal surface lifecycle reducer with bounded recovery budgets.
    public init(maxAutomaticRebuilds: Int = 1, maxReplayAttempts: Int = 3) {
        self.maxAutomaticRebuilds = max(0, maxAutomaticRebuilds)
        self.maxReplayAttempts = max(0, maxReplayAttempts)
    }

    /// Whether a render is queued or executing for the current generation.
    public var isRenderInFlight: Bool {
        if case .inFlight = renderPhase { return true }
        return false
    }

    /// The timestamp used for current stale-render elapsed logging, if any render is active or stalled.
    public var renderStartedAt: Double? {
        switch renderPhase {
        case .idle:
            nil
        case .inFlight(_, let enqueuedAt, let startedAt, _):
            startedAt ?? enqueuedAt
        case .stalled(_, let startedAt):
            startedAt
        }
    }

    /// Presentation that should be shown for the current lifecycle state.
    public var presentation: TerminalSurfacePresentation {
        if !isMounted {
            return hasSnapshot ? .snapshotFallback : .unavailable
        }

        switch renderPhase {
        case .stalled:
            if hasLiveFrame || hasPreservedFrame { return .renderStalledLiveFrame }
            if hasSnapshot { return .renderStalledSnapshot }
            return .unavailable
        case .idle, .inFlight:
            if isConnectionRecovering {
                if hasLiveFrame || hasPreservedFrame { return .reconnectingLiveFrame }
                if hasSnapshot { return .reconnectingSnapshot }
            }
            if hasLiveFrame || hasPreservedFrame { return .liveFrame }
            if hasSnapshot { return .snapshotFallback }
            return .waitingForFirstFrame
        }
    }

    /// Whether UI should show the snapshot fallback layer for the current presentation.
    public var shouldShowSnapshotFallback: Bool {
        switch presentation {
        case .snapshotFallback, .reconnectingSnapshot, .renderStalledSnapshot:
            true
        case .waitingForFirstFrame, .liveFrame, .reconnectingLiveFrame, .renderStalledLiveFrame, .unavailable:
            false
        }
    }

    /// Mounts a new active surface generation and clears per-generation state.
    public mutating func mountNewSurfaceGeneration() -> UInt64 {
        generation &+= 1
        renderPhase = .idle
        isMounted = true
        hasLiveFrame = false
        hasPreservedFrame = false
        hasAppliedOutputInGeneration = false
        renderBlockedUntilOutput = false
        replayRecovery = nil
        automaticRebuilds = 0
        return generation
    }

    /// Records that output reached the current generation, unblocking rebuilt renders.
    public mutating func markOutputApplied() {
        guard isMounted else { return }
        hasAppliedOutputInGeneration = true
        renderBlockedUntilOutput = false
        replayRecovery = nil
    }

    /// Updates whether a snapshot fallback is currently available.
    public mutating func markSnapshotAvailable(_ available: Bool) {
        hasSnapshot = available
    }

    /// Updates whether transport reconnect presentation should be shown.
    public mutating func markConnectionRecovering(_ recovering: Bool) {
        isConnectionRecovering = recovering
    }

    /// Requests a render for the current generation.
    ///
    /// A requested render starts in a queued state. The stale execution timer
    /// begins only after ``beginRenderExecution(generation:now:)`` marks that
    /// the surface executor is about to call Ghostty.
    public mutating func requestRender(now: Double) -> TerminalSurfaceRenderRequestDecision {
        guard isMounted else { return .blockedByStalledSurface }
        guard !renderBlockedUntilOutput else { return .blockedUntilOutput }
        switch renderPhase {
        case .idle:
            renderPhase = .inFlight(
                generation: generation,
                enqueuedAt: now,
                startedAt: nil,
                needsCoalescedRender: false
            )
            return .enqueue(generation: generation)
        case .inFlight(let generation, let enqueuedAt, let startedAt, _):
            renderPhase = .inFlight(
                generation: generation,
                enqueuedAt: enqueuedAt,
                startedAt: startedAt,
                needsCoalescedRender: true
            )
            return .coalesced
        case .stalled:
            return .blockedByStalledSurface
        }
    }

    /// Marks a queued render as executing on the surface generation executor.
    ///
    /// Returns `false` when the generation was already abandoned or no longer
    /// has a matching render request, in which case the caller must skip the
    /// Ghostty render call.
    public mutating func beginRenderExecution(generation executingGeneration: UInt64, now: Double) -> Bool {
        guard case .inFlight(let generation, let enqueuedAt, let startedAt, let needsCoalescedRender) = renderPhase,
              generation == executingGeneration else {
            return false
        }
        guard startedAt == nil else {
            return true
        }
        renderPhase = .inFlight(
            generation: generation,
            enqueuedAt: enqueuedAt,
            startedAt: now,
            needsCoalescedRender: needsCoalescedRender
        )
        return true
    }

    /// Checks whether an executing render has exceeded the given timeout.
    public mutating func markRenderStale(now: Double, timeout: Double) -> TerminalSurfaceRecoveryDecision {
        markRenderStale(now: now, renderTimeout: timeout, queuedTimeout: .infinity)
    }

    /// Checks whether a queued or executing render has exceeded its timeout.
    ///
    /// `queuedTimeout` covers executor starvation before Ghostty rendering
    /// begins. `renderTimeout` covers time spent inside the actual render call.
    public mutating func markRenderStale(
        now: Double,
        renderTimeout: Double,
        queuedTimeout: Double
    ) -> TerminalSurfaceRecoveryDecision {
        guard case .inFlight(let generation, let enqueuedAt, let startedAt, _) = renderPhase else {
            return .none
        }
        let staleStartedAt: Double
        if let startedAt {
            guard now - startedAt >= renderTimeout else { return .none }
            staleStartedAt = startedAt
        } else {
            guard now - enqueuedAt >= queuedTimeout else { return .none }
            staleStartedAt = enqueuedAt
        }
        renderPhase = .stalled(generation: generation, startedAt: staleStartedAt)
        guard automaticRebuilds < maxAutomaticRebuilds else {
            return .failClosed(stalledGeneration: generation)
        }
        automaticRebuilds += 1
        return .abandonAndRebuild(stalledGeneration: generation)
    }

    /// Completes a render for a generation and returns whether another coalesced frame is needed.
    public mutating func completeRender(generation completedGeneration: UInt64) -> TerminalSurfaceRenderCompletionDecision {
        guard case .inFlight(let generation, _, _, let needsCoalescedRender) = renderPhase,
              generation == completedGeneration else {
            return .ignoredStaleCompletion
        }
        if hasAppliedOutputInGeneration {
            hasLiveFrame = true
            hasPreservedFrame = false
        }
        renderPhase = .idle
        if needsCoalescedRender {
            return .enqueueCoalesced
        }
        return .idle
    }

    /// Abandons a stalled generation and prepares a rebuilt generation that waits for replay output.
    public mutating func didAbandonStalledSurface(stalledGeneration: UInt64) {
        guard case .stalled(let generation, _) = renderPhase,
              generation == stalledGeneration else { return }
        self.generation &+= 1
        renderPhase = .idle
        isMounted = true
        hasPreservedFrame = hasPreservedFrame || hasLiveFrame
        hasLiveFrame = false
        hasAppliedOutputInGeneration = false
        renderBlockedUntilOutput = true
        replayRecovery = ReplayRecovery(generation: self.generation, attempts: 0)
    }

    /// Begins the next replay attempt for a rebuilt generation waiting for output.
    public mutating func beginReplayAttempt() -> TerminalSurfaceReplayAttemptDecision {
        guard isMounted,
              renderBlockedUntilOutput,
              var recovery = replayRecovery,
              recovery.generation == generation else {
            return .none
        }
        guard recovery.attempts < maxReplayAttempts else {
            failClosedReplayRecovery(generation: recovery.generation)
            return .failClosed(generation: recovery.generation)
        }
        recovery.attempts += 1
        replayRecovery = recovery
        return .request(generation: recovery.generation, attempt: recovery.attempts)
    }

    /// Completes a replay attempt and decides whether to retry, unblock, or fail closed.
    public mutating func completeReplayAttempt(
        generation completedGeneration: UInt64,
        deliveredOutput: Bool
    ) -> TerminalSurfaceReplayCompletionDecision {
        guard isMounted,
              renderBlockedUntilOutput,
              let recovery = replayRecovery,
              recovery.generation == completedGeneration else {
            return .ignored
        }
        if deliveredOutput {
            return .delivered
        }
        guard recovery.attempts < maxReplayAttempts else {
            failClosedReplayRecovery(generation: recovery.generation)
            return .failClosed(generation: recovery.generation)
        }
        return .retry(generation: recovery.generation)
    }

    /// Returns whether the given generation is still waiting for replay output.
    public func isAwaitingReplayOutput(generation expectedGeneration: UInt64) -> Bool {
        isMounted
            && renderBlockedUntilOutput
            && replayRecovery?.generation == expectedGeneration
    }

    private mutating func failClosedReplayRecovery(generation failedGeneration: UInt64) {
        guard replayRecovery?.generation == failedGeneration else { return }
        replayRecovery = nil
        renderBlockedUntilOutput = false
        renderPhase = .idle
    }

    /// Dismantles the surface and invalidates pending generation work.
    public mutating func dismantle() {
        isMounted = false
        renderPhase = .idle
        hasLiveFrame = false
        hasPreservedFrame = false
        hasAppliedOutputInGeneration = false
        renderBlockedUntilOutput = false
        replayRecovery = nil
        automaticRebuilds = 0
        generation &+= 1
    }

}

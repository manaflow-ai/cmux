import Testing
@testable import CmuxMobileTerminalKit

@Test func terminalSurfaceSessionCoalescesRenderWhileInFlight() {
    var session = TerminalSurfaceSessionState()
    let generation = session.mountNewSurfaceGeneration()

    #expect(session.requestRender(now: 10) == .enqueue(generation: generation))
    #expect(session.requestRender(now: 10.1) == .coalesced)
    session.markOutputApplied()
    #expect(session.completeRender(generation: generation) == .enqueueCoalesced)
    #expect(session.presentation == .liveFrame)
    #expect(session.requestRender(now: 10.2) == .enqueue(generation: generation))
}

@Test func terminalSurfaceSessionStaleRenderDoesNotEnqueueAnotherRender() {
    var session = TerminalSurfaceSessionState()
    let generation = session.mountNewSurfaceGeneration()

    #expect(session.requestRender(now: 1) == .enqueue(generation: generation))
    #expect(session.markRenderStale(now: 100, timeout: 3) == .none)
    let didBeginRender = session.beginRenderExecution(generation: generation, now: 1)
    #expect(didBeginRender)
    #expect(session.markRenderStale(now: 5, timeout: 3) == .abandonAndRebuild(stalledGeneration: generation))
    #expect(session.requestRender(now: 5.1) == .blockedByStalledSurface)
    #expect(session.renderPhase == .stalled(generation: generation, startedAt: 1))
}

@Test func terminalSurfaceSessionQueuedRenderCanTimeOutBeforeExecution() {
    var session = TerminalSurfaceSessionState()
    let generation = session.mountNewSurfaceGeneration()

    #expect(session.requestRender(now: 1) == .enqueue(generation: generation))
    #expect(session.markRenderStale(now: 5, renderTimeout: 3, queuedTimeout: 10) == .none)
    #expect(session.requestRender(now: 5.1) == .coalesced)
    #expect(session.markRenderStale(now: 11, renderTimeout: 3, queuedTimeout: 10) == .abandonAndRebuild(stalledGeneration: generation))
    #expect(session.renderPhase == .stalled(generation: generation, startedAt: 1))
}

@Test func terminalSurfaceSessionStalledPresentationKeepsLastFrameVisible() {
    var session = TerminalSurfaceSessionState()
    let generation = session.mountNewSurfaceGeneration()

    #expect(session.requestRender(now: 1) == .enqueue(generation: generation))
    session.markOutputApplied()
    #expect(session.completeRender(generation: generation) == .idle)
    #expect(session.presentation == .liveFrame)

    #expect(session.requestRender(now: 2) == .enqueue(generation: generation))
    let didBeginRender = session.beginRenderExecution(generation: generation, now: 2)
    #expect(didBeginRender)
    #expect(session.markRenderStale(now: 6, timeout: 3) == .abandonAndRebuild(stalledGeneration: generation))
    #expect(session.presentation == .renderStalledLiveFrame)
    #expect(!session.shouldShowSnapshotFallback)
}

@Test func terminalSurfaceSessionStalledPresentationUsesSnapshotBeforeFirstLiveFrame() {
    var session = TerminalSurfaceSessionState()
    let generation = session.mountNewSurfaceGeneration()
    session.markSnapshotAvailable(true)

    #expect(session.requestRender(now: 1) == .enqueue(generation: generation))
    let didBeginRender = session.beginRenderExecution(generation: generation, now: 1)
    #expect(didBeginRender)
    #expect(session.markRenderStale(now: 4, timeout: 3) == .abandonAndRebuild(stalledGeneration: generation))
    #expect(session.presentation == .renderStalledSnapshot)
    #expect(session.shouldShowSnapshotFallback)
}

@Test func terminalSurfaceSessionAbandoningStaleGenerationInvalidatesLateCompletion() {
    var session = TerminalSurfaceSessionState()
    let oldGeneration = session.mountNewSurfaceGeneration()

    #expect(session.requestRender(now: 1) == .enqueue(generation: oldGeneration))
    session.markOutputApplied()
    #expect(session.completeRender(generation: oldGeneration) == .idle)
    #expect(session.presentation == .liveFrame)

    #expect(session.requestRender(now: 2) == .enqueue(generation: oldGeneration))
    let didBeginRender = session.beginRenderExecution(generation: oldGeneration, now: 2)
    #expect(didBeginRender)
    #expect(session.markRenderStale(now: 5, timeout: 3) == .abandonAndRebuild(stalledGeneration: oldGeneration))
    session.didAbandonStalledSurface(stalledGeneration: oldGeneration)

    #expect(session.generation != oldGeneration)
    #expect(session.presentation == .liveFrame)
    #expect(session.completeRender(generation: oldGeneration) == .ignoredStaleCompletion)
    #expect(session.requestRender(now: 5.1) == .blockedUntilOutput)
}

@Test func terminalSurfaceSessionRebuiltSurfaceDoesNotRenderBeforeReplay() {
    var session = TerminalSurfaceSessionState()
    let oldGeneration = session.mountNewSurfaceGeneration()

    #expect(session.requestRender(now: 1) == .enqueue(generation: oldGeneration))
    session.markOutputApplied()
    #expect(session.completeRender(generation: oldGeneration) == .idle)
    #expect(session.presentation == .liveFrame)

    #expect(session.requestRender(now: 2) == .enqueue(generation: oldGeneration))
    let didBeginRender = session.beginRenderExecution(generation: oldGeneration, now: 2)
    #expect(didBeginRender)
    #expect(session.markRenderStale(now: 5, timeout: 3) == .abandonAndRebuild(stalledGeneration: oldGeneration))
    session.didAbandonStalledSurface(stalledGeneration: oldGeneration)
    let rebuiltGeneration = session.generation

    #expect(session.requestRender(now: 5.1) == .blockedUntilOutput)
    #expect(session.presentation == .liveFrame)
    #expect(!session.hasLiveFrame)
    #expect(session.hasPreservedFrame)
    #expect(session.automaticRebuilds == 1)

    session.markOutputApplied()
    #expect(session.requestRender(now: 5.3) == .enqueue(generation: rebuiltGeneration))
    #expect(session.completeRender(generation: rebuiltGeneration) == .idle)
    #expect(session.hasLiveFrame)
    #expect(!session.hasPreservedFrame)
    #expect(session.automaticRebuilds == 1)
}

@Test func terminalSurfaceSessionRetriesRebuildReplayBeforeFailingClosed() {
    var session = TerminalSurfaceSessionState(maxAutomaticRebuilds: 1, maxReplayAttempts: 2)
    let oldGeneration = session.mountNewSurfaceGeneration()

    #expect(session.requestRender(now: 1) == .enqueue(generation: oldGeneration))
    session.markOutputApplied()
    #expect(session.completeRender(generation: oldGeneration) == .idle)
    #expect(session.requestRender(now: 2) == .enqueue(generation: oldGeneration))
    let didBeginRender = session.beginRenderExecution(generation: oldGeneration, now: 2)
    #expect(didBeginRender)
    #expect(session.markRenderStale(now: 5, timeout: 3) == .abandonAndRebuild(stalledGeneration: oldGeneration))
    session.didAbandonStalledSurface(stalledGeneration: oldGeneration)
    let rebuiltGeneration = session.generation

    #expect(session.beginReplayAttempt() == .request(generation: rebuiltGeneration, attempt: 1))
    #expect(session.completeReplayAttempt(generation: rebuiltGeneration, deliveredOutput: false) == .retry(generation: rebuiltGeneration))
    #expect(session.beginReplayAttempt() == .request(generation: rebuiltGeneration, attempt: 2))
    #expect(session.completeReplayAttempt(generation: rebuiltGeneration, deliveredOutput: false) == .failClosed(generation: rebuiltGeneration))
    #expect(session.requestRender(now: 5.5) == .enqueue(generation: rebuiltGeneration))
    #expect(session.presentation == .liveFrame)
    #expect(session.completeRender(generation: rebuiltGeneration) == .idle)
    session.markOutputApplied()
    #expect(session.requestRender(now: 5.6) == .enqueue(generation: rebuiltGeneration))
    #expect(session.completeRender(generation: rebuiltGeneration) == .idle)
    #expect(session.hasLiveFrame)
}

@Test func terminalSurfaceSessionReplayDeliveryWaitsForOutputBeforeUnblockingRender() {
    var session = TerminalSurfaceSessionState()
    let oldGeneration = session.mountNewSurfaceGeneration()

    #expect(session.requestRender(now: 1) == .enqueue(generation: oldGeneration))
    session.markOutputApplied()
    #expect(session.completeRender(generation: oldGeneration) == .idle)
    #expect(session.requestRender(now: 2) == .enqueue(generation: oldGeneration))
    let didBeginRender = session.beginRenderExecution(generation: oldGeneration, now: 2)
    #expect(didBeginRender)
    #expect(session.markRenderStale(now: 5, timeout: 3) == .abandonAndRebuild(stalledGeneration: oldGeneration))
    session.didAbandonStalledSurface(stalledGeneration: oldGeneration)
    let rebuiltGeneration = session.generation

    #expect(session.beginReplayAttempt() == .request(generation: rebuiltGeneration, attempt: 1))
    #expect(session.completeReplayAttempt(generation: rebuiltGeneration, deliveredOutput: true) == .delivered)
    #expect(session.requestRender(now: 5.1) == .blockedUntilOutput)
    #expect(session.isAwaitingReplayOutput(generation: rebuiltGeneration))

    session.markOutputApplied()
    #expect(session.requestRender(now: 5.2) == .enqueue(generation: rebuiltGeneration))
}

@Test func terminalSurfaceSessionPersistentStallFailsClosedAfterBoundedRebuild() {
    var session = TerminalSurfaceSessionState(maxAutomaticRebuilds: 1)
    let oldGeneration = session.mountNewSurfaceGeneration()

    #expect(session.requestRender(now: 1) == .enqueue(generation: oldGeneration))
    let didBeginOldRender = session.beginRenderExecution(generation: oldGeneration, now: 1)
    #expect(didBeginOldRender)
    #expect(session.markRenderStale(now: 4, timeout: 3) == .abandonAndRebuild(stalledGeneration: oldGeneration))
    session.didAbandonStalledSurface(stalledGeneration: oldGeneration)

    let rebuiltGeneration = session.generation
    session.markOutputApplied()
    #expect(session.requestRender(now: 5) == .enqueue(generation: rebuiltGeneration))
    let didBeginRebuiltRender = session.beginRenderExecution(generation: rebuiltGeneration, now: 5)
    #expect(didBeginRebuiltRender)
    #expect(session.markRenderStale(now: 8, timeout: 3) == .failClosed(stalledGeneration: rebuiltGeneration))
    #expect(session.requestRender(now: 8.1) == .blockedByStalledSurface)
    #expect(session.generation == rebuiltGeneration)
}

@Test func terminalSurfaceSessionRebuildBudgetPersistsAfterReplay() {
    var session = TerminalSurfaceSessionState(maxAutomaticRebuilds: 1)
    let oldGeneration = session.mountNewSurfaceGeneration()

    #expect(session.requestRender(now: 1) == .enqueue(generation: oldGeneration))
    let didBeginOldRender = session.beginRenderExecution(generation: oldGeneration, now: 1)
    #expect(didBeginOldRender)
    #expect(session.markRenderStale(now: 4, timeout: 3) == .abandonAndRebuild(stalledGeneration: oldGeneration))
    session.didAbandonStalledSurface(stalledGeneration: oldGeneration)

    let rebuiltGeneration = session.generation
    #expect(session.requestRender(now: 4.1) == .blockedUntilOutput)
    session.markOutputApplied()
    #expect(session.requestRender(now: 4.2) == .enqueue(generation: rebuiltGeneration))
    #expect(session.completeRender(generation: rebuiltGeneration) == .idle)
    #expect(session.automaticRebuilds == 1)

    #expect(session.requestRender(now: 5) == .enqueue(generation: rebuiltGeneration))
    let didBeginRebuiltRender = session.beginRenderExecution(generation: rebuiltGeneration, now: 5)
    #expect(didBeginRebuiltRender)
    #expect(session.markRenderStale(now: 8, timeout: 3) == .failClosed(stalledGeneration: rebuiltGeneration))
}

@Test func terminalSurfaceSessionReconnectPresentationPreservesLatestFrame() {
    var session = TerminalSurfaceSessionState()
    let generation = session.mountNewSurfaceGeneration()

    #expect(session.requestRender(now: 1) == .enqueue(generation: generation))
    session.markOutputApplied()
    #expect(session.completeRender(generation: generation) == .idle)
    session.markConnectionRecovering(true)

    #expect(session.presentation == .reconnectingLiveFrame)
    #expect(!session.shouldShowSnapshotFallback)
}

@Test func terminalSurfaceSessionReconnectPresentationUsesSnapshotWhenNoLiveFrameExists() {
    var session = TerminalSurfaceSessionState()
    _ = session.mountNewSurfaceGeneration()
    session.markSnapshotAvailable(true)
    session.markConnectionRecovering(true)

    #expect(session.presentation == .reconnectingSnapshot)
    #expect(session.shouldShowSnapshotFallback)
}

@Test func terminalSurfaceSessionDismantleInvalidatesInFlightWork() {
    var session = TerminalSurfaceSessionState()
    let generation = session.mountNewSurfaceGeneration()

    #expect(session.requestRender(now: 1) == .enqueue(generation: generation))
    session.dismantle()

    #expect(session.completeRender(generation: generation) == .ignoredStaleCompletion)
    #expect(session.presentation == .unavailable)
}

import Testing

/// Keeps test-only wall-clock waiters from flooding the shared MainActor
/// executor while the rest of CmuxMobileShellTests runs in parallel.
///
/// This gate is deliberately scoped to the polling/count helpers rather than
/// the whole test target: tests that do not need a wall-clock assertion keep
/// their normal parallelism.
actor MobileShellWallClockWaitGate {
    // Swift Testing has independent root suites, so a process-wide gate is
    // the only way to serialize their wall-clock waiters without serializing
    // unrelated test bodies.
    static let processWide = MobileShellWallClockWaitGate()

    private var isHeld = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func withLock<Value: Sendable>(
        _ operation: @Sendable () async throws -> Value
    ) async throws -> Value {
        await acquire()
        do {
            let value = try await operation()
            release()
            return value
        } catch {
            release()
            throw error
        }
    }

    private func acquire() async {
        guard isHeld else {
            isHeld = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        guard !waiters.isEmpty else {
            isHeld = false
            return
        }
        waiters.removeFirst().resume()
    }
}

enum MobileShellWallClockWaitPolicy {
    /// Three seconds is shorter than a loaded whole-suite run. Keep the
    /// default poll budget comfortably above that scheduling window.
    static let defaultPollAttempts = 3_000
    static let defaultWaitTimeoutNanoseconds: UInt64 = 30_000_000_000

    private static let suiteScaleThresholdNanoseconds: UInt64 = 3_000_000_000
    private static let pollIntervalNanoseconds: UInt64 = 10_000_000

    /// Preserve intentionally short assertion windows while giving every
    /// suite-scale wait enough time to survive a busy shared executor.
    static func timeoutNanoseconds(for requested: UInt64) -> UInt64 {
        guard shouldSerializeWait(timeoutNanoseconds: requested) else { return requested }
        return max(requested, defaultWaitTimeoutNanoseconds)
    }

    static func shouldSerializeWait(timeoutNanoseconds: UInt64) -> Bool {
        timeoutNanoseconds >= suiteScaleThresholdNanoseconds
    }

    static func shouldSerializePoll(attempts: Int) -> Bool {
        attempts >= Int(suiteScaleThresholdNanoseconds / pollIntervalNanoseconds)
    }
}

private actor MobileShellWaitGateProbe {
    private var activeCount = 0
    private var maximumActiveCount = 0
    private var firstEntered = false
    private var secondAttempted = false
    private var firstReleased = false
    private var firstEnteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var secondAttemptedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func enter() {
        activeCount += 1
        maximumActiveCount = max(maximumActiveCount, activeCount)
        if !firstEntered {
            firstEntered = true
            resume(&firstEnteredWaiters)
        }
    }

    func leave() {
        activeCount -= 1
    }

    func markSecondAttempted() {
        secondAttempted = true
        resume(&secondAttemptedWaiters)
    }

    func waitUntilFirstEntered() async {
        guard !firstEntered else { return }
        await withCheckedContinuation { firstEnteredWaiters.append($0) }
    }

    func waitUntilSecondAttempted() async {
        guard !secondAttempted else { return }
        await withCheckedContinuation { secondAttemptedWaiters.append($0) }
    }

    func holdFirstOperation() async {
        guard !firstReleased else { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func releaseFirstOperation() {
        firstReleased = true
        resume(&releaseWaiters)
    }

    func maximumActive() -> Int {
        maximumActiveCount
    }

    private func resume(_ waiters: inout [CheckedContinuation<Void, Never>]) {
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            waiter.resume()
        }
    }
}

@Test("mobile shell wall-clock waits are serialized without serializing other tests")
func mobileShellWallClockWaitGateSerializesConcurrentWaits() async {
    let gate = MobileShellWallClockWaitGate()
    let probe = MobileShellWaitGateProbe()

    let first = Task {
        _ = try? await gate.withLock {
            await probe.enter()
            await probe.holdFirstOperation()
            await probe.leave()
        }
    }
    await probe.waitUntilFirstEntered()

    let second = Task {
        await probe.markSecondAttempted()
        _ = try? await gate.withLock {
            await probe.enter()
            await probe.leave()
        }
    }
    await probe.waitUntilSecondAttempted()

    let maximumBeforeRelease = await probe.maximumActive()
    #expect(maximumBeforeRelease == 1)

    await probe.releaseFirstOperation()
    _ = await first.value
    _ = await second.value

    let maximumOverall = await probe.maximumActive()
    #expect(maximumOverall == 1)
}

@Test("mobile shell long waits retain suite scheduling headroom")
func mobileShellWallClockWaitPolicyProvidesSuiteHeadroom() {
    #expect(
        MobileShellWallClockWaitPolicy.timeoutNanoseconds(for: 10_000_000_000)
            == MobileShellWallClockWaitPolicy.defaultWaitTimeoutNanoseconds
    )
    #expect(
        MobileShellWallClockWaitPolicy.timeoutNanoseconds(for: 200_000_000)
            == 200_000_000
    )
    #expect(!MobileShellWallClockWaitPolicy.shouldSerializeWait(timeoutNanoseconds: 250_000_000))
    #expect(!MobileShellWallClockWaitPolicy.shouldSerializePoll(attempts: 100))
    #expect(MobileShellWallClockWaitPolicy.shouldSerializePoll(attempts: 3_000))
}

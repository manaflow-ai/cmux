import Foundation

actor WorkspaceListRequestGate {
    private var count = 0
    private var holdFirst = false
    private var holdSecond = false
    private var holdThird = false
    private var usesOrdinalTitles = false
    private var firstHeld = false
    private var secondHeld = false
    private var thirdHeld = false
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var secondReleaseContinuation: CheckedContinuation<Void, Never>?
    private var thirdReleaseContinuation: CheckedContinuation<Void, Never>?
    private var reachedWaiters: [CheckedContinuation<Void, Never>] = []
    private var secondReachedWaiters: [CheckedContinuation<Void, Never>] = []
    private var thirdReachedWaiters: [CheckedContinuation<Void, Never>] = []
    private var countWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func setHoldFirst(_ hold: Bool) {
        holdFirst = hold
    }

    func setHoldSecond(_ hold: Bool) {
        holdSecond = hold
    }

    func setHoldThird(_ hold: Bool) {
        holdThird = hold
    }

    func setUsesOrdinalTitles(_ usesTitles: Bool) {
        usesOrdinalTitles = usesTitles
    }

    func beforeResponse() async -> String? {
        count += 1
        let readyCountWaiters = countWaiters.filter { count >= $0.0 }
        countWaiters.removeAll { count >= $0.0 }
        for (_, waiter) in readyCountWaiters { waiter.resume() }
        let ordinal = count
        if ordinal == 1, holdFirst {
            firstHeld = true
            let waiters = reachedWaiters
            reachedWaiters = []
            for waiter in waiters { waiter.resume() }
            await withCheckedContinuation { releaseContinuation = $0 }
        }
        if ordinal == 2, holdSecond {
            secondHeld = true
            let waiters = secondReachedWaiters
            secondReachedWaiters = []
            for waiter in waiters { waiter.resume() }
            await withCheckedContinuation { secondReleaseContinuation = $0 }
        }
        if ordinal == 3, holdThird {
            thirdHeld = true
            let waiters = thirdReachedWaiters
            thirdReachedWaiters = []
            for waiter in waiters { waiter.resume() }
            await withCheckedContinuation { thirdReleaseContinuation = $0 }
        }
        guard usesOrdinalTitles else { return nil }
        return ordinal == 1 ? "Stale Workspace" : "Fresh Workspace"
    }

    func waitUntilFirstReached() async {
        if firstHeld { return }
        await withCheckedContinuation { reachedWaiters.append($0) }
    }

    func waitUntilSecondReached() async {
        if secondHeld { return }
        await withCheckedContinuation { secondReachedWaiters.append($0) }
    }

    func waitUntilThirdReached() async {
        if thirdHeld { return }
        await withCheckedContinuation { thirdReachedWaiters.append($0) }
    }

    func waitUntilRequestCount(_ expectedCount: Int) async {
        if count >= expectedCount { return }
        await withCheckedContinuation { countWaiters.append((expectedCount, $0)) }
    }

    func releaseFirst() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    func releaseSecond() {
        secondReleaseContinuation?.resume()
        secondReleaseContinuation = nil
    }

    func releaseThird() {
        thirdReleaseContinuation?.resume()
        thirdReleaseContinuation = nil
    }

    func requestCount() -> Int { count }
}

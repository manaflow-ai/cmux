actor ProcessPerformanceExerciseGate {
    private var captureReleased = false
    private var captureWaiters: [CheckedContinuation<Void, Never>] = []
    private var finished = false
    private var finishWaiters: [CheckedContinuation<Void, Never>] = []
    private var generation: UInt64?
    private var generationWaiters: [UInt64: CheckedContinuation<UInt64?, Never>] = [:]
    private var cancelledGenerationWaiters: Set<UInt64> = []
    private var joinCount = 0
    private var joinTargets: [UInt64: (Int, CheckedContinuation<Bool, Never>)] = [:]
    private var cancelledJoinWaiters: Set<UInt64> = []
    private var nextWaiterID: UInt64 = 0

    func waitForCaptureRelease() async {
        guard !captureReleased else { return }
        await withCheckedContinuation { captureWaiters.append($0) }
    }

    func releaseCapture() {
        captureReleased = true
        let waiters = captureWaiters
        captureWaiters.removeAll(keepingCapacity: false)
        waiters.forEach { $0.resume() }
    }

    func waitUntilFinished() async {
        guard !finished else { return }
        await withCheckedContinuation { finishWaiters.append($0) }
    }

    func finish() {
        finished = true
        let waiters = finishWaiters
        finishWaiters.removeAll(keepingCapacity: false)
        waiters.forEach { $0.resume() }
        generationWaiters.values.forEach { $0.resume(returning: nil) }
        generationWaiters.removeAll(keepingCapacity: false)
        joinTargets.values.forEach { $0.1.resume(returning: false) }
        joinTargets.removeAll(keepingCapacity: false)
    }

    func recordGeneration(_ generation: UInt64) {
        guard self.generation == nil else { return }
        self.generation = generation
        let waiters = generationWaiters.values
        generationWaiters.removeAll(keepingCapacity: false)
        waiters.forEach { $0.resume(returning: generation) }
    }

    func recordJoin() {
        joinCount += 1
        var remaining: [UInt64: (Int, CheckedContinuation<Bool, Never>)] = [:]
        for (id, (target, continuation)) in joinTargets {
            if joinCount >= target {
                continuation.resume(returning: true)
            } else {
                remaining[id] = (target, continuation)
            }
        }
        joinTargets = remaining
    }

    func waitForGeneration() async -> UInt64? {
        if let generation { return generation }
        let id = makeWaiterID()
        return await Self.withTimeout { await self.waitForGenerationSignal(id: id) }
    }

    func waitForJoinCount(_ target: Int) async -> Bool {
        if joinCount >= target { return true }
        let id = makeWaiterID()
        return await Self.withTimeout {
            await self.waitForJoinSignal(id: id, target: target)
        } ?? false
    }

    private nonisolated static func withTimeout<Value: Sendable>(
        _ operation: @escaping @Sendable () async -> Value?
    ) async -> Value? {
        await withTaskGroup(of: Value?.self) { group in
            group.addTask { await operation() }
            group.addTask {
                try? await Task.sleep(for: .seconds(10))
                return nil
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }

    private func makeWaiterID() -> UInt64 {
        nextWaiterID &+= 1
        return nextWaiterID
    }

    private func waitForGenerationSignal(id: UInt64) async -> UInt64? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                Task { self.installGenerationWaiter(id: id, continuation: continuation) }
            }
        } onCancel: {
            Task { await self.cancelGenerationWaiter(id: id) }
        }
    }

    private func installGenerationWaiter(
        id: UInt64,
        continuation: CheckedContinuation<UInt64?, Never>
    ) {
        if let generation {
            continuation.resume(returning: generation)
        } else if finished || cancelledGenerationWaiters.remove(id) != nil {
            continuation.resume(returning: nil)
        } else {
            generationWaiters[id] = continuation
        }
    }

    private func cancelGenerationWaiter(id: UInt64) {
        if let continuation = generationWaiters.removeValue(forKey: id) {
            continuation.resume(returning: nil)
        } else {
            cancelledGenerationWaiters.insert(id)
        }
    }

    private func waitForJoinSignal(id: UInt64, target: Int) async -> Bool {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                Task {
                    self.installJoinWaiter(
                        id: id,
                        target: target,
                        continuation: continuation
                    )
                }
            }
        } onCancel: {
            Task { await self.cancelJoinWaiter(id: id) }
        }
    }

    private func installJoinWaiter(
        id: UInt64,
        target: Int,
        continuation: CheckedContinuation<Bool, Never>
    ) {
        if joinCount >= target {
            continuation.resume(returning: true)
        } else if finished || cancelledJoinWaiters.remove(id) != nil {
            continuation.resume(returning: false)
        } else {
            joinTargets[id] = (target, continuation)
        }
    }

    private func cancelJoinWaiter(id: UInt64) {
        if let continuation = joinTargets.removeValue(forKey: id)?.1 {
            continuation.resume(returning: false)
        } else {
            cancelledJoinWaiters.insert(id)
        }
    }
}

enum ProcessPerformanceExerciseContext {
    @TaskLocal static var isListenerExerciseRequest = false
}

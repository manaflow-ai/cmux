import Foundation

/// Coalesces workspace diff loads and bounds repository scans across clients.
actor MobileWorkingTreeDiffCoordinator {
    typealias Loader = @Sendable (String, String) async throws -> MobileWorkingTreeDiffPayload

    private let maximumConcurrentLoads: Int
    private let loader: Loader
    private var activeLoadCount = 0
    private var inFlightLoads: [String: MobileWorkingTreeDiffInFlightLoad] = [:]
    private var slotWaiters: [(UUID, CheckedContinuation<Void, any Error>)] = []

    init(
        maximumConcurrentLoads: Int = 2,
        loader: @escaping Loader = { directory, title in
            try await MobileWorkingTreeDiffLoader().loadPayload(directory: directory, title: title)
        }
    ) {
        self.maximumConcurrentLoads = max(1, maximumConcurrentLoads)
        self.loader = loader
    }

    func load(key: String, directory: String, title: String) async throws -> MobileWorkingTreeDiffPayload {
        let waiterID = UUID()
        let loadID: UUID
        let task: Task<MobileWorkingTreeDiffPayload, any Error>
        if var existing = inFlightLoads[key] {
            existing.waiters.insert(waiterID)
            inFlightLoads[key] = existing
            loadID = existing.id
            task = existing.task
        } else {
            loadID = UUID()
            task = Task { [loader] in
                try await self.acquireSlot()
                do {
                    let payload = try await loader(directory, title)
                    self.releaseSlot()
                    return payload
                } catch {
                    self.releaseSlot()
                    throw error
                }
            }
            inFlightLoads[key] = MobileWorkingTreeDiffInFlightLoad(id: loadID, task: task, waiters: [waiterID])
        }

        return try await withTaskCancellationHandler {
            do {
                let payload = try await task.value
                try Task.checkCancellation()
                finishWaiter(waiterID, key: key, loadID: loadID)
                return payload
            } catch {
                finishWaiter(waiterID, key: key, loadID: loadID)
                throw error
            }
        } onCancel: {
            Task { await self.cancelWaiter(waiterID, key: key, loadID: loadID) }
        }
    }

    private func finishWaiter(
        _ waiterID: UUID,
        key: String,
        loadID: UUID
    ) {
        guard var existing = inFlightLoads[key], existing.id == loadID else { return }
        existing.waiters.remove(waiterID)
        if existing.waiters.isEmpty {
            inFlightLoads[key] = nil
        } else {
            inFlightLoads[key] = existing
        }
    }

    private func cancelWaiter(
        _ waiterID: UUID,
        key: String,
        loadID: UUID
    ) {
        guard var existing = inFlightLoads[key], existing.id == loadID else { return }
        existing.waiters.remove(waiterID)
        if existing.waiters.isEmpty {
            existing.task.cancel()
            inFlightLoads[key] = nil
        } else {
            inFlightLoads[key] = existing
        }
    }

    private func acquireSlot() async throws {
        try Task.checkCancellation()
        guard activeLoadCount >= maximumConcurrentLoads else {
            activeLoadCount += 1
            return
        }
        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    slotWaiters.append((waiterID, continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelSlotWaiter(waiterID) }
        }
    }

    private func releaseSlot() {
        if slotWaiters.isEmpty {
            activeLoadCount -= 1
            return
        }
        let (_, continuation) = slotWaiters.removeFirst()
        continuation.resume()
    }

    private func cancelSlotWaiter(_ waiterID: UUID) {
        guard let index = slotWaiters.firstIndex(where: { $0.0 == waiterID }) else { return }
        let (_, continuation) = slotWaiters.remove(at: index)
        continuation.resume(throwing: CancellationError())
    }
}

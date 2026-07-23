import Foundation

/// Owns bounded, cancellation-aware physical filesystem reads independently of
/// the cancelable refresh tasks that requested them. Replacement generations
/// wait for the old read of the same key, while a dedicated global lane remains
/// available if cwd reads block on disconnected volumes.
actor CmuxConfigActionCatalogReadCoordinator {
    static let shared = CmuxConfigActionCatalogReadCoordinator()

    private let maximumGlobalReadCount: Int
    private let maximumGeneralReadCount: Int
    private let maximumPendingReadCount: Int
    private let pendingReadObserver: @Sendable (String) -> Void
    private let readCompletionObserver: @Sendable (String) -> Void
    private var activeReads: [String: ActiveRead] = [:]
    private var pendingReadKeys: [String] = []
    private var activeGlobalReadCount = 0
    private var activeGeneralReadCount = 0

    init(
        maximumGlobalReadCount: Int = 1,
        maximumGeneralReadCount: Int = 2,
        maximumPendingReadCount: Int = 64,
        pendingReadObserver: @escaping @Sendable (String) -> Void = { _ in },
        readCompletionObserver: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        precondition(maximumGlobalReadCount > 0)
        precondition(maximumGeneralReadCount > 0)
        precondition(maximumPendingReadCount >= 0)
        self.maximumGlobalReadCount = maximumGlobalReadCount
        self.maximumGeneralReadCount = maximumGeneralReadCount
        self.maximumPendingReadCount = maximumPendingReadCount
        self.pendingReadObserver = pendingReadObserver
        self.readCompletionObserver = readCompletionObserver
    }

    func run(
        key: String,
        lane: Lane,
        requestID: UUID,
        operation: @escaping @Sendable () async -> CmuxConfigActionCatalogSource?
    ) async -> CmuxConfigActionCatalogSource? {
        while !Task.isCancelled {
            switch await waitForRead(
                key: key,
                lane: lane,
                requestID: requestID,
                operation: operation
            ) {
            case .source(let source):
                return source
            case .retry:
                continue
            case .unavailable, .cancelled:
                return nil
            }
        }
        return nil
    }

    private func waitForRead(
        key: String,
        lane: Lane,
        requestID: UUID,
        operation: @escaping @Sendable () async -> CmuxConfigActionCatalogSource?
    ) async -> WaitResult {
        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: .cancelled)
                    return
                }
                if activeReads[key] == nil {
                    let canStartImmediately = canStartRead(in: lane)
                    guard canStartImmediately
                            || pendingReadKeys.count < maximumPendingReadCount else {
                        continuation.resume(returning: .cancelled)
                        return
                    }
                    activeReads[key] = ActiveRead(
                        id: UUID(),
                        requestID: requestID,
                        lane: lane,
                        operation: operation,
                        isRunning: false,
                        ownerTask: nil,
                        waiters: [:]
                    )
                    if canStartImmediately {
                        startRead(key: key)
                    } else {
                        pendingReadKeys.append(key)
                        pendingReadObserver(key)
                    }
                }
                activeReads[key]?.waiters[waiterID] = Waiter(
                    requestID: requestID,
                    continuation: continuation
                )
            }
        } onCancel: {
            Task { await self.cancelWaiter(key: key, waiterID: waiterID) }
        }
    }

    private func startRead(key: String) {
        guard var read = activeReads[key],
              !read.isRunning,
              canStartRead(in: read.lane) else {
            return
        }
        read.isRunning = true
        occupySlot(in: read.lane)
        let readID = read.id
        let operation = read.operation
        let ownerTask = Task { [weak self] in
            let source = await operation()
            await self?.finishRead(key: key, readID: readID, source: source)
        }
        read.ownerTask = ownerTask
        activeReads[key] = read
    }

    private func finishRead(
        key: String,
        readID: UUID,
        source: CmuxConfigActionCatalogSource?
    ) {
        guard let read = activeReads[key], read.id == readID else { return }
        activeReads.removeValue(forKey: key)
        releaseSlot(in: read.lane)
        readCompletionObserver(key)
        for waiter in read.waiters.values {
            let result: WaitResult
            if waiter.requestID != read.requestID {
                result = .retry
            } else if let source {
                result = .source(source)
            } else {
                result = .unavailable
            }
            waiter.continuation.resume(returning: result)
        }
        startPendingReadsIfPossible()
    }

    private func cancelWaiter(key: String, waiterID: UUID) {
        guard var read = activeReads[key],
              let waiter = read.waiters.removeValue(forKey: waiterID) else {
            return
        }
        if read.waiters.isEmpty, !read.isRunning {
            activeReads.removeValue(forKey: key)
            pendingReadKeys.removeAll(where: { $0 == key })
            startPendingReadsIfPossible()
        } else {
            if read.waiters.isEmpty {
                read.ownerTask?.cancel()
            }
            activeReads[key] = read
        }
        waiter.continuation.resume(returning: .cancelled)
    }

    private func canStartRead(in lane: Lane) -> Bool {
        switch lane {
        case .global:
            return activeGlobalReadCount < maximumGlobalReadCount
        case .general:
            return activeGeneralReadCount < maximumGeneralReadCount
        }
    }

    private func occupySlot(in lane: Lane) {
        switch lane {
        case .global:
            activeGlobalReadCount += 1
        case .general:
            activeGeneralReadCount += 1
        }
    }

    private func releaseSlot(in lane: Lane) {
        switch lane {
        case .global:
            activeGlobalReadCount = max(0, activeGlobalReadCount - 1)
        case .general:
            activeGeneralReadCount = max(0, activeGeneralReadCount - 1)
        }
    }

    private func startPendingReadsIfPossible() {
        var index = 0
        while index < pendingReadKeys.count {
            let key = pendingReadKeys[index]
            guard let read = activeReads[key], !read.isRunning else {
                pendingReadKeys.remove(at: index)
                continue
            }
            guard canStartRead(in: read.lane) else {
                index += 1
                continue
            }
            pendingReadKeys.remove(at: index)
            startRead(key: key)
        }
    }
}

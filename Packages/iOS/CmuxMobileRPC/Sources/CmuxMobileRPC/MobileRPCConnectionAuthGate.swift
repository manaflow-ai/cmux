import Foundation

enum MobileRPCConnectionAuthMode: Equatable, Sendable {
    case connectionAuthenticated
    case legacyPerRequest
}

/// Deduplicates the Stack-auth negotiation for one installed transport.
/// A new session connection id replaces the cached result automatically.
actor MobileRPCConnectionAuthGate {
    private struct Current {
        let id: UUID
        let connectionID: UUID
        let task: Task<MobileRPCConnectionAuthMode, any Error>
        var waiters: Int
        var resolved: Bool
    }

    private let taskTimeout = RPCTaskTimeout()
    private let timedOutResetNanoseconds: UInt64
    private var current: Current?
    private var abandoned: [UUID: Task<MobileRPCConnectionAuthMode, any Error>] = [:]
    private var blockedUntil: UInt64?

    init(timedOutResetNanoseconds: UInt64 = 30_000_000_000) {
        self.timedOutResetNanoseconds = timedOutResetNanoseconds
    }

    func mode(
        for connectionID: UUID,
        timeoutNanoseconds: UInt64,
        authenticate: @escaping @Sendable () async throws -> MobileRPCConnectionAuthMode
    ) async throws -> MobileRPCConnectionAuthMode {
        if let blockedUntil {
            guard DispatchTime.now().uptimeNanoseconds >= blockedUntil else {
                throw MobileShellConnectionError.requestTimedOut
            }
            self.blockedUntil = nil
        }
        let taskID: UUID
        let task: Task<MobileRPCConnectionAuthMode, any Error>
        if let existing = current, existing.connectionID == connectionID {
            taskID = existing.id
            task = existing.task
            current?.waiters += 1
        } else {
            taskID = UUID()
            let created = Task {
                try await authenticate()
            }
            current = Current(
                id: taskID,
                connectionID: connectionID,
                task: created,
                waiters: 1,
                resolved: false
            )
            task = created
        }

        do {
            let mode = try await taskTimeout.value(
                task,
                timeoutNanoseconds: timeoutNanoseconds
            )
            resolveWaiter(id: taskID)
            return mode
        } catch MobileShellConnectionError.requestTimedOut {
            abandonWaiter(id: taskID)
            throw MobileShellConnectionError.requestTimedOut
        } catch is CancellationError {
            abandonWaiter(id: taskID)
            throw CancellationError()
        } catch {
            if current?.id == taskID {
                current = nil
            }
            throw error
        }
    }

    private func resolveWaiter(id: UUID) {
        guard current?.id == id else { return }
        current?.waiters -= 1
        current?.resolved = true
    }

    private func abandonWaiter(id: UUID) {
        guard current?.id == id else { return }
        current?.waiters -= 1
        guard current?.waiters == 0,
              current?.resolved == false,
              let task = current?.task else { return }
        task.cancel()
        current = nil
        blockedUntil = DispatchTime.now().uptimeNanoseconds &+ timedOutResetNanoseconds
        abandoned[id] = task
        Task.detached { [weak self] in
            _ = await task.result
            await self?.clearAbandoned(id: id)
        }
    }

    private func clearAbandoned(id: UUID) {
        abandoned[id] = nil
    }
}

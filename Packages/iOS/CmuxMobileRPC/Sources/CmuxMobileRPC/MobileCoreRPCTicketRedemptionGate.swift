import CMUXMobileCore
import Foundation

actor MobileCoreRPCTicketRedemptionGate {
    private struct Current {
        var id: UUID
        var task: Task<CmxAttachTicket, any Error>
        var completionObserver: Task<Void, Never>?
        var waiters: Int
        var timedOutUntil: UInt64?
        var isCompleted: Bool
    }

    private struct Abandoned {
        var task: Task<CmxAttachTicket, any Error>
        var completionObserver: Task<Void, Never>?
    }

    private var current: Current?
    private var abandoned: [UUID: Abandoned] = [:]
    private let taskTimeout = RPCTaskTimeout()
    private let timedOutResetNanoseconds: UInt64
    private let nowNanoseconds: @Sendable () -> UInt64

    init(
        timedOutResetNanoseconds: UInt64 = 30_000_000_000,
        nowNanoseconds: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }
    ) {
        self.timedOutResetNanoseconds = timedOutResetNanoseconds
        self.nowNanoseconds = nowNanoseconds
    }

    var waiterCount: Int {
        current?.waiters ?? 0
    }

    func ticket(
        timeoutNanoseconds: UInt64,
        provider: @escaping @Sendable () async throws -> CmxAttachTicket
    ) async throws -> CmxAttachTicket {
        let id: UUID
        let task: Task<CmxAttachTicket, any Error>
        if let existing = current, let timedOutUntil = existing.timedOutUntil {
            guard nowNanoseconds() >= timedOutUntil else {
                throw MobileShellConnectionError.requestTimedOut
            }
            if !existing.isCompleted {
                abandon(existing, cancelTask: true)
            }
            current = nil
        }
        if let existing = current {
            id = existing.id
            task = existing.task
            current?.waiters += 1
        } else {
            id = UUID()
            task = Task { try await provider() }
            current = Current(
                id: id,
                task: task,
                completionObserver: nil,
                waiters: 1,
                timedOutUntil: nil,
                isCompleted: false
            )
            let completionObserver = Task { [weak self] in
                _ = await task.result
                await self?.complete(id: id)
            }
            current?.completionObserver = completionObserver
        }

        do {
            let ticket = try await taskTimeout.value(task, timeoutNanoseconds: timeoutNanoseconds)
            clear(id: id)
            return ticket
        } catch MobileShellConnectionError.requestTimedOut {
            timeoutWaiter(id: id)
            throw MobileShellConnectionError.requestTimedOut
        } catch is CancellationError {
            cancelWaiter(id: id)
            throw CancellationError()
        } catch {
            clear(id: id)
            throw error
        }
    }

    private func timeoutWaiter(id: UUID) {
        guard current?.id == id, let task = current?.task else { return }
        current?.waiters -= 1
        guard let waiters = current?.waiters, waiters <= 0 else {
            return
        }
        current = Current(
            id: id,
            task: task,
            completionObserver: current?.completionObserver,
            waiters: 0,
            timedOutUntil: nowNanoseconds() &+ timedOutResetNanoseconds,
            isCompleted: false
        )
        task.cancel()
    }

    private func cancelWaiter(id: UUID) {
        guard current?.id == id, let task = current?.task else { return }
        current?.waiters -= 1
        guard let waiters = current?.waiters, waiters <= 0 else {
            return
        }
        if let existing = current {
            abandon(existing, cancelTask: true)
        }
        current = nil
        task.cancel()
    }

    private func clear(id: UUID) {
        if current?.id == id {
            current?.completionObserver?.cancel()
            current = nil
        }
        abandoned[id] = nil
    }

    private func complete(id: UUID) {
        if var existing = current, existing.id == id {
            if existing.timedOutUntil == nil {
                current = nil
            } else {
                existing.isCompleted = true
                current = existing
            }
        }
        abandoned[id] = nil
    }

    private func abandon(_ existing: Current, cancelTask: Bool) {
        for (_, abandonedWork) in abandoned {
            abandonedWork.task.cancel()
        }
        if cancelTask {
            existing.task.cancel()
        }
        abandoned[existing.id] = Abandoned(
            task: existing.task,
            completionObserver: existing.completionObserver
        )
    }
}

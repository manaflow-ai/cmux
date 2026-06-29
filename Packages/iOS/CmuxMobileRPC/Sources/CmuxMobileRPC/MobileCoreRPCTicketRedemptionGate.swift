import CMUXMobileCore
import Foundation

actor MobileCoreRPCTicketRedemptionGate {
    private struct Current {
        var id: UUID
        var task: Task<CmxAttachTicket, any Error>
        var waiters: Int
        var timedOutUntil: UInt64?
        var isCompleted: Bool
    }

    private var current: Current?
    private var abandoned: [UUID: Task<CmxAttachTicket, any Error>] = [:]
    private let taskTimeout = RPCTaskTimeout()
    private let timedOutResetNanoseconds: UInt64

    init(timedOutResetNanoseconds: UInt64 = 30_000_000_000) {
        self.timedOutResetNanoseconds = timedOutResetNanoseconds
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
            guard DispatchTime.now().uptimeNanoseconds >= timedOutUntil else {
                throw MobileShellConnectionError.requestTimedOut
            }
            if !existing.isCompleted {
                guard abandoned.isEmpty else {
                    throw MobileShellConnectionError.requestTimedOut
                }
                abandoned[existing.id] = existing.task
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
            current = Current(id: id, task: task, waiters: 1, timedOutUntil: nil, isCompleted: false)
            Task.detached { [weak self] in
                _ = await task.result
                await self?.complete(id: id)
            }
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
            waiters: 0,
            timedOutUntil: DispatchTime.now().uptimeNanoseconds &+ timedOutResetNanoseconds,
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
        clear(id: id)
        task.cancel()
    }

    private func clear(id: UUID) {
        if current?.id == id {
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
}

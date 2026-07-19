import Foundation

/// Deduplicates Stack access-token acquisition across mobile RPC clients owned by the same shell.
public actor RPCStackTokenGate {
    private var currentByScope: [RPCStackTokenScopeKey: RPCStackTokenTaskState] = [:]
    private var abandonedByScope: [RPCStackTokenScopeKey: [UUID: Task<String, any Error>]] = [:]
    private let taskTimeout = RPCTaskTimeout()
    private let timedOutResetNanoseconds: UInt64

    /// Creates a gate that suppresses retries after every waiter times out or cancels.
    public init(timedOutResetNanoseconds: UInt64 = 30_000_000_000) {
        self.timedOutResetNanoseconds = timedOutResetNanoseconds
    }

    func token(
        scope: MobileRPCAuthScope? = nil,
        timeoutNanoseconds: UInt64,
        provider: @escaping @Sendable () async throws -> String
    ) async throws -> String {
        let scopeKey = scope.map(RPCStackTokenScopeKey.scoped) ?? .unscoped
        let id: UUID
        let task: Task<String, any Error>
        if let existing = currentByScope[scopeKey], let timedOutUntil = existing.timedOutUntil {
            guard DispatchTime.now().uptimeNanoseconds >= timedOutUntil else {
                throw MobileShellConnectionError.requestTimedOut
            }
            guard abandonedByScope[scopeKey]?.isEmpty != false else {
                throw MobileShellConnectionError.requestTimedOut
            }
            abandonedByScope[scopeKey, default: [:]][existing.id] = existing.task
            currentByScope[scopeKey] = nil
        }
        if var existing = currentByScope[scopeKey] {
            id = existing.id
            task = existing.task
            existing.waiters += 1
            currentByScope[scopeKey] = existing
        } else {
            id = UUID()
            task = Task { try await provider() }
            currentByScope[scopeKey] = RPCStackTokenTaskState(
                id: id,
                task: task,
                waiters: 1,
                timedOutUntil: nil
            )
            Task.detached { [weak self] in
                _ = await task.result
                await self?.clear(scopeKey: scopeKey, id: id)
            }
        }

        do {
            let token = try await taskTimeout.value(task, timeoutNanoseconds: timeoutNanoseconds)
            clear(scopeKey: scopeKey, id: id)
            return token
        } catch MobileShellConnectionError.requestTimedOut {
            timeoutWaiter(scopeKey: scopeKey, id: id)
            throw MobileShellConnectionError.requestTimedOut
        } catch is CancellationError {
            cancelWaiter(scopeKey: scopeKey, id: id)
            throw CancellationError()
        } catch {
            clear(scopeKey: scopeKey, id: id)
            throw error
        }
    }

    /// Cancels credential work owned by one invalidated auth scope without
    /// disturbing requests from another signed-in scope.
    public func invalidate(scope: MobileRPCAuthScope) {
        scope.revoke()
        let scopeKey = RPCStackTokenScopeKey.scoped(scope)
        currentByScope.removeValue(forKey: scopeKey)?.task.cancel()
        let abandoned = abandonedByScope.removeValue(forKey: scopeKey)?.values ?? [:].values
        for task in abandoned { task.cancel() }
    }

    private func timeoutWaiter(scopeKey: RPCStackTokenScopeKey, id: UUID) {
        guard var current = currentByScope[scopeKey], current.id == id else { return }
        current.waiters -= 1
        guard current.waiters <= 0 else {
            currentByScope[scopeKey] = current
            return
        }
        currentByScope[scopeKey] = RPCStackTokenTaskState(
            id: id,
            task: current.task,
            waiters: 0,
            timedOutUntil: DispatchTime.now().uptimeNanoseconds &+ timedOutResetNanoseconds
        )
        current.task.cancel()
    }

    private func cancelWaiter(scopeKey: RPCStackTokenScopeKey, id: UUID) {
        guard var current = currentByScope[scopeKey], current.id == id else { return }
        current.waiters -= 1
        guard current.waiters <= 0 else {
            currentByScope[scopeKey] = current
            return
        }
        currentByScope[scopeKey] = RPCStackTokenTaskState(
            id: id,
            task: current.task,
            waiters: 0,
            timedOutUntil: DispatchTime.now().uptimeNanoseconds &+ timedOutResetNanoseconds
        )
        current.task.cancel()
    }

    private func clear(scopeKey: RPCStackTokenScopeKey, id: UUID) {
        if currentByScope[scopeKey]?.id == id {
            currentByScope[scopeKey] = nil
        }
        abandonedByScope[scopeKey]?[id] = nil
        if abandonedByScope[scopeKey]?.isEmpty == true {
            abandonedByScope[scopeKey] = nil
        }
    }
}

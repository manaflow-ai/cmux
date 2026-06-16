import CmuxControlSocket
import CmuxTerminal
import Foundation

private let surfaceReadTextSocketWorkerEncoder = ControlResponseEncoder()
private let surfaceReadTextReadinessWaiter = SurfaceReadTextReadinessWaiter(maxWaiters: 16)

extension TerminalController {
    nonisolated func socketWorkerSurfaceReadTextResponse(_ request: ControlRequest) -> String {
        let firstResult = socketWorkerCoordinatorResult(for: request)
        guard let surfaceID = Self.retryableReadDemandSurfaceID(
            from: firstResult,
            request: request
        ) else {
            return surfaceReadTextSocketWorkerEncoder.response(id: request.id, firstResult)
        }

        guard let readinessWait = surfaceReadTextReadinessWaiter.prepareWait(for: surfaceID) else {
            return surfaceReadTextSocketWorkerEncoder.response(id: request.id, firstResult)
        }
        defer {
            surfaceReadTextReadinessWaiter.cancel(readinessWait)
        }

        let retryRequest = Self.readTextRequest(request, pinnedToSurfaceID: surfaceID)
        let secondResult = socketWorkerCoordinatorResult(for: retryRequest)
        guard Self.retryableReadDemandSurfaceID(from: secondResult, request: retryRequest) == surfaceID else {
            return surfaceReadTextSocketWorkerEncoder.response(id: request.id, secondResult)
        }

        guard surfaceReadTextReadinessWaiter.wait(readinessWait, timeout: 5) else {
            return surfaceReadTextSocketWorkerEncoder.response(id: request.id, secondResult)
        }

        let readyResult = socketWorkerCoordinatorResult(for: retryRequest)
        return surfaceReadTextSocketWorkerEncoder.response(id: request.id, readyResult)
    }

    private nonisolated func socketWorkerCoordinatorResult(for request: ControlRequest) -> ControlCallResult {
        v2MainSync {
            v2RefreshKnownRefs()
            return controlCommandCoordinator.handle(request) ?? .err(
                code: "method_not_found",
                message: "Unknown method",
                data: nil
            )
        }
    }

    private nonisolated static func retryableReadDemandSurfaceID(
        from result: ControlCallResult,
        request: ControlRequest
    ) -> UUID? {
        guard request.method == "surface.read_text",
              v2BoolValue(request.params["start_if_needed"]) == true,
              case .err(let code, _, let data) = result,
              code == "terminal_not_ready",
              case .object(let object)? = data,
              case .string(let rawSurfaceID)? = object["surface_id"] else {
            return nil
        }
        return UUID(uuidString: rawSurfaceID)
    }

    private nonisolated static func readTextRequest(
        _ request: ControlRequest,
        pinnedToSurfaceID surfaceID: UUID
    ) -> ControlRequest {
        var params = request.params
        params["surface_id"] = .string(surfaceID.uuidString)
        return ControlRequest(id: request.id, method: request.method, params: params)
    }

    private nonisolated static func v2BoolValue(_ value: JSONValue?) -> Bool? {
        switch value {
        case .bool(let value):
            return value
        case .int(let value):
            return value != 0
        case .double(let value):
            return value != 0
        case .string(let value):
            switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "1", "true", "yes", "on":
                return true
            case "0", "false", "no", "off":
                return false
            default:
                return nil
            }
        default:
            return nil
        }
    }
}

private final class SurfaceReadTextReadinessWait: @unchecked Sendable {
    let surfaceID: UUID
    let waiterID: UUID
    let semaphore = DispatchSemaphore(value: 0)

    init(surfaceID: UUID, waiterID: UUID) {
        self.surfaceID = surfaceID
        self.waiterID = waiterID
    }
}

private final class SurfaceReadTextReadinessWaiter: @unchecked Sendable {
    private final class Entry {
        var observer: NSObjectProtocol?
        var waiters: [UUID: SurfaceReadTextReadinessWait] = [:]
    }

    private let lock = NSLock()
    private let maxWaiters: Int
    private var entries: [UUID: Entry] = [:]
    private var activeWaiterCount = 0

    init(maxWaiters: Int) {
        self.maxWaiters = maxWaiters
    }

    func prepareWait(for surfaceID: UUID) -> SurfaceReadTextReadinessWait? {
        let wait = SurfaceReadTextReadinessWait(surfaceID: surfaceID, waiterID: UUID())
        var observerToRemove: NSObjectProtocol?
        var shouldInstallObserver = false

        lock.lock()
        if activeWaiterCount >= maxWaiters {
            lock.unlock()
            return nil
        }

        let entry = entries[surfaceID] ?? Entry()
        if entry.observer == nil {
            shouldInstallObserver = true
        }
        entry.waiters[wait.waiterID] = wait
        entries[surfaceID] = entry
        activeWaiterCount += 1
        lock.unlock()

        if shouldInstallObserver {
            let observer = NotificationCenter.default.addObserver(
                forName: .terminalSurfaceDidBecomeReady,
                object: nil,
                queue: nil
            ) { [weak self] notification in
                self?.signalReady(surfaceID: surfaceID, notification: notification)
            }

            lock.lock()
            if let currentEntry = entries[surfaceID], currentEntry.observer == nil {
                currentEntry.observer = observer
            } else {
                observerToRemove = observer
            }
            lock.unlock()
        }

        if let observerToRemove {
            NotificationCenter.default.removeObserver(observerToRemove)
        }
        return wait
    }

    func wait(_ wait: SurfaceReadTextReadinessWait, timeout: TimeInterval) -> Bool {
        let result = wait.semaphore.wait(timeout: .now() + timeout) == .success
        if !result {
            cancel(wait)
        }
        return result
    }

    func cancel(_ wait: SurfaceReadTextReadinessWait) {
        var observerToRemove: NSObjectProtocol?

        lock.lock()
        if let entry = entries[wait.surfaceID],
           entry.waiters.removeValue(forKey: wait.waiterID) != nil {
            activeWaiterCount = max(0, activeWaiterCount - 1)
            if entry.waiters.isEmpty {
                entries.removeValue(forKey: wait.surfaceID)
                observerToRemove = entry.observer
            }
        }
        lock.unlock()

        if let observerToRemove {
            NotificationCenter.default.removeObserver(observerToRemove)
        }
    }

    private func signalReady(surfaceID: UUID, notification: Notification) {
        guard notification.userInfo?["surfaceId"] as? UUID == surfaceID else { return }

        var observerToRemove: NSObjectProtocol?
        let waits: [SurfaceReadTextReadinessWait]

        lock.lock()
        if let entry = entries.removeValue(forKey: surfaceID) {
            waits = Array(entry.waiters.values)
            activeWaiterCount = max(0, activeWaiterCount - waits.count)
            observerToRemove = entry.observer
        } else {
            waits = []
        }
        lock.unlock()

        if let observerToRemove {
            NotificationCenter.default.removeObserver(observerToRemove)
        }
        for wait in waits {
            wait.semaphore.signal()
        }
    }
}

import Foundation

extension V2ControlService {
    func requestDirectoryRefresh(run: UUID) {
        guard directorySyncTask == nil, (socket != nil || httpMode) else { return }
        let taskID = UUID()
        directorySyncTaskID = taskID
        directorySyncTask = Task { [weak self] in
            guard let self else { return }
            do { _ = try await self.refreshDirectory() }
            catch { await self.maintenanceFailed(error, schema: "directory.request.v1", run: run) }
            await self.directorySyncFinished(run: run, taskID: taskID)
        }
    }

    private func directorySyncFinished(run: UUID, taskID: UUID) {
        guard runID == run, directorySyncTaskID == taskID else { return }
        directorySyncTask = nil
        directorySyncTaskID = nil
    }

    func scheduleMaintenance(run: UUID) {
        guard runID == run, status == .ready else { return }
        renewalTask?.cancel()
        renewalTask = Task { [weak self] in await self?.maintain(run: run) }
    }

    private func maintain(run: UUID) async {
        while runID == run, status == .ready, !Task.isCancelled {
            let now = dependencies.now().timeIntervalSince1970
            let ticketDue = due(cache.ticket?.refreshAfter, schema: "ticket.request.v1", now: now)
            let relayDue = due(cache.relayCredentials.map(\.refreshAfter).min(), schema: "relay.request.v1", now: now)
            let directoryDue = due(cache.directory.map { $0.permissionExpiresAt - 300 }, schema: "directory.request.v1", now: now)
            let next = min(ticketDue, relayDue, directoryDue)
            do { try await dependencies.sleep(max(0, next - now)) }
            catch { return }
            guard runID == run, !Task.isCancelled, (socket != nil || httpMode) else { return }
            let deadline = dependencies.now().timeIntervalSince1970 + 0.1
            // Independent refreshes share the same socket but no peer teardown path.
            await withTaskGroup(of: Void.self) { group in
                if ticketDue <= deadline {
                    group.addTask {
                        do { _ = try await self.refreshAPITicket() }
                        catch { await self.maintenanceFailed(error, schema: "ticket.request.v1", run: run) }
                    }
                }
                if relayDue <= deadline {
                    group.addTask {
                        do { _ = try await self.refreshRelayCredentials() }
                        catch { await self.maintenanceFailed(error, schema: "relay.request.v1", run: run) }
                    }
                }
                if directoryDue <= deadline {
                    group.addTask {
                        do { _ = try await self.refreshDirectory() }
                        catch { await self.maintenanceFailed(error, schema: "directory.request.v1", run: run) }
                    }
                }
            }
        }
    }

    private func due(_ timestamp: Int?, schema: String, now: TimeInterval) -> TimeInterval {
        max(Double(timestamp ?? Int(now)), cooldowns[schema]?.timeIntervalSince1970 ?? 0, cooldowns[operation(schema)]?.timeIntervalSince1970 ?? 0)
    }

    private func maintenanceFailed(_ error: any Error, schema: String, run: UUID) {
        guard runID == run, !Task.isCancelled else { return }
        let mapped = mapFailure(error)
        // The receive owner already records server cooldowns. Do not count one
        // rejected schema twice or overwrite its long backoff with a short one.
        if case .server = mapped {} else { record(mapped, schema: schema) }
        let retry = dependencies.now().addingTimeInterval(30 * (0.8 + 0.4 * dependencies.jitter()))
        cooldowns[operation(schema)] = max(cooldowns[operation(schema)] ?? retry, retry)
    }
}

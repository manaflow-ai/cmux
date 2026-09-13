import Foundation

@MainActor
extension CmuxTuiSurfaceProvider {
    /// Runs one close-family command, reconnecting and retrying once when the attempt
    /// died with the link. Close verbs are idempotent, so the retry is safe.
    func runCloseCommand(_ arguments: (_ socketPath: String) -> [String]) async throws -> Data {
        let connected = try await links.connected(machineID: machineID)
        guard let link = await links.link(machineID: machineID) else { throw ProviderError.machineAsleep(machineID) }
        do {
            return try await link.run(arguments: arguments(connected.socketPath))
        } catch {
            if Self.isSelectorNotFound(error) { throw error }
            let reconnected = try await links.connected(machineID: machineID)
            guard let fresh = await links.link(machineID: machineID) else { throw error }
            return try await fresh.run(arguments: arguments(reconnected.socketPath))
        }
    }

    /// `workspace <id> close` detaches terminals into the pool; the sidebar's full
    /// delete closes each terminal first through `CloudTreeNodeActions`.
    func closeRemoteWorkspace(id: String) async throws {
        do {
            _ = try await runCloseCommand { CloudTuiCommandLine.closeWorkspaceArguments(socketPath: $0, workspaceID: id) }
        } catch {
            // A stale sidebar row may outlive the daemon workspace. Treat the
            // daemon's idempotent not-found response as local reconciliation;
            // unrelated terminal resources remain untouched.
            guard Self.isSelectorNotFound(error) else { throw error }
        }
        reconcileRemovedRemoteWorkspace(id)
        scheduleRefresh()
    }
}

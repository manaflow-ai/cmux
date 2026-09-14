import Foundation

@MainActor
extension CmuxTuiSurfaceProvider {
    /// `terminal <id> close`; a terminal whose process already exited is gone from
    /// cmux-tui's selectors, so its tab is closed instead. Either way the resource
    /// leaves the catalog now and the next snapshot confirms.
    func closeTerminal(_ id: SurfaceResourceID) async throws {
        try await closeTerminal(id, fallbackTabID: nil)
    }

    func closeTerminal(_ id: SurfaceResourceID, fallbackTabID: String?) async throws {
        pendingRemoteCreations.removeValue(forKey: id)
        do {
            _ = try await runCloseCommand { CloudTuiCommandLine.closeTerminalArguments(socketPath: $0, terminalID: id.key) }
        } catch {
            guard let tabID = fallbackTabID ?? tabByTerminal[id.key], Self.isSelectorNotFound(error) else { throw error }
            _ = try await runCloseCommand { CloudTuiCommandLine.closeTabArguments(socketPath: $0, tabID: tabID) }
        }
        closeLocalPanes(showing: [id])
        catalog.remove(id, from: self)
        scheduleRefresh()
    }

    /// A closed terminal has no pane to show any more: every local pane that projected it
    /// goes too, instead of lingering as a dead attach the person has to close by hand.
    private func closeLocalPanes(showing ids: [SurfaceResourceID]) {
        let wanted = Set(ids)
        for projection in catalog.snapshot.projections where wanted.contains(projection.resource) {
            SurfacePaneFactory.close(panelID: projection.panelID, in: projection.workspaceID)
        }
    }

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

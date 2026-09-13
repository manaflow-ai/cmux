import Foundation

@MainActor
extension CmuxTuiSurfaceProvider {
    // MARK: Headless terminal I/O (agent primitives; no pane involved)

    /// Type `text` into the remote terminal exactly as given (no newline appended).
    func sendText(terminalID: String, text: String) async throws {
        let connected = try await links.connected(machineID: machineID)
        guard let link = await links.link(machineID: machineID) else { throw ProviderError.machineAsleep(machineID) }
        _ = try await link.run(arguments: CloudTuiCommandLine.writeArguments(socketPath: connected.socketPath, terminalID: terminalID, text: text))
    }

    /// Press named keys (`enter`, `ctrl+c`, …) in the remote terminal, in order.
    func sendKeys(terminalID: String, keys: [String]) async throws {
        let connected = try await links.connected(machineID: machineID)
        guard let link = await links.link(machineID: machineID) else { throw ProviderError.machineAsleep(machineID) }
        _ = try await link.run(arguments: CloudTuiCommandLine.keysArguments(socketPath: connected.socketPath, terminalID: terminalID, keys: keys))
    }

    /// The remote terminal's visible screen, as the daemon reports it
    /// (`cols`, `rows`, `cursor_row`, `cursor_col`, `cursor_visible`, `text`).
    func readScreen(terminalID: String) async throws -> [String: Any] {
        let connected = try await links.connected(machineID: machineID)
        guard let link = await links.link(machineID: machineID) else { throw ProviderError.machineAsleep(machineID) }
        let data = try await link.run(arguments: CloudTuiCommandLine.screenReadArguments(socketPath: connected.socketPath, terminalID: terminalID))
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    /// Block until the screen matches `pattern` (or the daemon-side timeout elapses):
    /// `{matched, text}`. The link call itself is given headroom beyond the timeout.
    func waitForScreen(terminalID: String, pattern: String, timeoutMs: Int?) async throws -> [String: Any] {
        let connected = try await links.connected(machineID: machineID)
        guard let link = await links.link(machineID: machineID) else { throw ProviderError.machineAsleep(machineID) }
        // Non-positive requests mean the daemon default, so the link headroom is computed
        // from the same value the daemon will use; huge requests are clamped so the
        // Duration math cannot overflow.
        let effectiveMs = Self.clampedWaitTimeoutMs(timeoutMs)
        let linkTimeout = Duration.milliseconds(effectiveMs + 5_000)
        let data = try await link.run(
            arguments: CloudTuiCommandLine.screenWaitArguments(socketPath: connected.socketPath, terminalID: terminalID, pattern: pattern, timeoutMs: effectiveMs),
            timeout: linkTimeout
        )
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    /// `terminal <id> close`; a terminal whose process already exited is gone from
    /// cmux-tui's selectors, so its tab is closed instead. Either way the resource
    /// leaves the catalog now and the next snapshot confirms.
    func closeTerminal(_ id: SurfaceResourceID) async throws {
        try await closeTerminal(id, fallbackTabID: nil)
    }

    func closeTerminal(_ id: SurfaceResourceID, fallbackTabID: String?) async throws {
        discardPendingRemoteCreation(id)
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

    /// Compatibility fallback for callers that only have a terminal identity. A terminal with
    /// several views has no safe implicit placement. Returning nil keeps the projection
    /// placement-neutral until a caller supplies an exact tab id.
    static func defaultRemoteView(for resource: SurfaceResource) -> SurfaceRemoteView? {
        guard resource.kind != .display, let views = resource.remoteViews, views.count == 1 else { return nil }
        return views[0]
    }

}

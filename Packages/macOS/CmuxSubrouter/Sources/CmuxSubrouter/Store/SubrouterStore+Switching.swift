extension SubrouterStore {
    /// Switches a provider's active account — the single mutation path shared
    /// by the Agents panel, the footer switcher, and `cmux subrouter switch`.
    ///
    /// Sequence: mark the switch pending → run the `sr` CLI (the daemon has
    /// no switch endpoint) → `POST /_subrouter/reload-accounts` so the daemon
    /// re-reads the store it routes by → fresh refresh so every surface shows
    /// the authoritative result. A reload failure after a successful `sr` run
    /// is surfaced as a snapshot warning, not a thrown error, because the
    /// on-disk switch already landed.
    ///
    /// - Parameters:
    ///   - provider: The provider to switch (Codex or Claude).
    ///   - accountID: The daemon account id (Codex email / Claude profile).
    /// - Throws: ``SubrouterSwitchError`` when the switch itself fails.
    public func switchAccount(provider: SubrouterProvider, accountID: String) async throws {
        guard configuration.isEnabled else {
            throw SubrouterSwitchError.integrationDisabled
        }
        if configuration.isRemoteEndpoint {
            throw SubrouterSwitchError.remoteServerManagesSelection(
                serverName: configuration.serverName ?? configuration.endpoint.baseURL.host() ?? "remote"
            )
        }
        guard pendingSwitchAccountID == nil else {
            throw SubrouterSwitchError.switchAlreadyInFlight
        }
        pendingSwitchAccountID = accountID
        lastSwitchError = nil
        defer { pendingSwitchAccountID = nil }

        do {
            try await switcher.switchAccount(
                provider: provider,
                accountID: accountID,
                commandPath: configuration.commandPath
            )
        } catch let error as SubrouterSwitchError {
            lastSwitchError = error
            throw error
        } catch {
            // Unknown errors never carry raw dumps into user-facing state.
            let wrapped = SubrouterSwitchError.commandFailed(
                description: "unexpected error (\(type(of: error)))"
            )
            lastSwitchError = wrapped
            throw wrapped
        }

        var reloadWarning: String?
        do {
            let reload = try await client.reloadAccounts(endpoint: configuration.endpoint)
            if !reload.ok {
                reloadWarning = "daemon reload reported failure"
            }
        } catch let error as SubrouterClientError {
            reloadWarning = error.shortDescription
        } catch {
            reloadWarning = "unexpected error (\(type(of: error)))"
        }
        await performFreshRefresh(reason: "switch")
        if let reloadWarning, snapshot.lastErrorDescription == nil {
            recordWarning(reloadWarning)
        }
    }

    /// Asks the daemon to hot-reload its on-disk account store, then
    /// refreshes. Backs `cmux subrouter reload`.
    ///
    /// - Returns: The daemon's reload outcome.
    /// - Throws: ``SubrouterClientError`` when the daemon is unreachable.
    @discardableResult
    public func reloadDaemonAccounts() async throws -> SubrouterReloadResult {
        let result = try await client.reloadAccounts(endpoint: configuration.endpoint)
        await performFreshRefresh(reason: "reload")
        return result
    }

    /// Records a non-fatal warning on the snapshot (e.g. a reload failure
    /// after a successful on-disk switch).
    func recordWarning(_ description: String) {
        snapshot.lastErrorDescription = description
    }
}

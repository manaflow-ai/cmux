extension SubrouterStore {
    /// Switches a provider's active account — the single mutation path shared
    /// by the Agents panel, the footer switcher, and `cmux subrouter switch`.
    ///
    /// Local daemon: mark the switch pending → run the `sr` CLI (the local
    /// switch is a credential-file rewrite) → `POST /_subrouter/reload-accounts`
    /// so the daemon re-reads the store it routes by → fresh refresh so every
    /// surface shows the authoritative result. A reload failure after a
    /// successful `sr` run is surfaced as a snapshot warning, not a thrown
    /// error, because the on-disk switch already landed.
    ///
    /// Remote server: `POST /_subrouter/switch-account` performs the same
    /// rewrite on the server host and invalidates its usage cache itself
    /// (reload-accounts is loopback-only), so only the fresh refresh follows.
    /// Servers predating the endpoint (404/501) surface as
    /// ``SubrouterSwitchError/remoteServerManagesSelection(serverName:)``.
    ///
    /// - Parameters:
    ///   - provider: The provider to switch (Codex or Claude).
    ///   - accountID: The daemon account id (Codex email / Claude profile).
    /// - Throws: ``SubrouterSwitchError`` when the switch itself fails.
    public func switchAccount(provider: SubrouterProvider, accountID: String) async throws {
        // Refresh externally owned configuration (sr's server registry)
        // first: the remote-vs-local and enabled guards below must evaluate
        // the registry's current selection, not a stale cache.
        if let configurationPreflight {
            await configurationPreflight()
        }
        guard configuration.isEnabled else {
            throw SubrouterSwitchError.integrationDisabled
        }
        guard pendingSwitch == nil else {
            throw SubrouterSwitchError.switchAlreadyInFlight
        }
        pendingSwitch = SubrouterPendingSwitch(provider: provider, accountID: accountID)
        lastSwitchError = nil
        defer { pendingSwitch = nil }

        // The switch below can take up to 30 seconds. Capture the endpoint
        // it was validated against: if settings change mid-switch
        // (integration disabled, endpoint repointed), the post-switch
        // reload/refresh must not hit a daemon the guards above never saw.
        let endpointAtSwitch = configuration.endpoint
        let isRemote = configuration.isRemoteEndpoint

        do {
            if isRemote {
                _ = try await client.switchAccount(
                    endpoint: endpointAtSwitch,
                    provider: provider,
                    accountID: accountID
                )
            } else {
                try await switcher.switchAccount(
                    provider: provider,
                    accountID: accountID,
                    commandPath: configuration.commandPath
                )
            }
        } catch let error as SubrouterSwitchError {
            lastSwitchError = error
            throw error
        } catch let error as SubrouterClientError {
            let mapped: SubrouterSwitchError
            if case .httpStatus(let code, _) = error, code == 404 || code == 501 {
                // The server predates /_subrouter/switch-account (404 falls
                // through to the daemon's catch-all; 501 means unwired).
                mapped = .remoteServerManagesSelection(
                    serverName: configuration.serverName
                        ?? endpointAtSwitch.baseURL.host() ?? "remote"
                )
            } else {
                mapped = .commandFailed(description: error.shortDescription)
            }
            lastSwitchError = mapped
            throw mapped
        } catch {
            // Unknown errors never carry raw dumps into user-facing state.
            let wrapped = SubrouterSwitchError.commandFailed(
                description: "unexpected error (\(type(of: error)))"
            )
            lastSwitchError = wrapped
            throw wrapped
        }

        // Revalidate after the switch: it already landed on the daemon host
        // (it cannot be undone), but no follow-up daemon traffic may run
        // once the integration was disabled or the endpoint changed
        // underneath the switch.
        guard configuration.isEnabled, configuration.endpoint == endpointAtSwitch else {
            return
        }

        var reloadWarning: String?
        // The hot reload only applies to the local daemon: reload-accounts
        // is loopback-only, and the remote switch endpoint already
        // invalidated the server's usage cache.
        if !isRemote {
            do {
                let reload = try await client.reloadAccounts(endpoint: endpointAtSwitch)
                if !reload.ok {
                    reloadWarning = String(
                        localized: "subrouter.error.reloadFailed",
                        defaultValue: "Daemon reload reported failure"
                    )
                }
            } catch let error as SubrouterClientError {
                reloadWarning = error.shortDescription
            } catch {
                reloadWarning = "unexpected error (\(type(of: error)))"
            }
        }
        // Sessions stay out of the post-switch refresh: nothing that runs
        // after a switch reads them (the switch payload and UI are
        // usage-driven), and `/_subrouter/sessions` returns the daemon's
        // whole routing history — the pending state must not wait on that
        // transfer. Only the socket verbs that read sessions (`status`,
        // `sessions`) fetch them.
        await performFreshRefresh(reason: "switch", includingSessions: false)
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
        // The reload verb's payload never reads sessions; skip the
        // whole-history transfer here too.
        await performFreshRefresh(reason: "reload", includingSessions: false)
        return result
    }

    /// Records a non-fatal warning on the snapshot (e.g. a reload failure
    /// after a successful on-disk switch).
    func recordWarning(_ description: String) {
        snapshot.lastErrorDescription = description
    }
}

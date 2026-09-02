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
    /// Remote server: account selection is per agent session on the hosted
    /// pool, so a global switch is intentionally rejected. The UI hides row
    /// actions for remote pools and the CLI receives the same typed error.
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
        if configuration.isRemoteEndpoint {
            let error = SubrouterSwitchError.remoteServerManagesSelection(
                serverName: configuration.serverName
                    ?? configuration.endpoint.baseURL.host()
                    ?? "remote"
            )
            lastSwitchError = error
            throw error
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
        do {
            try await switcher.switchAccount(
                provider: provider,
                accountID: accountID,
                commandPath: configuration.commandPath,
                target: configuration.accountTarget ?? .local
            )
        } catch let error as SubrouterSwitchError {
            lastSwitchError = error
            throw error
        } catch let error as SubrouterClientError {
            Self.logger.error(
                "Subrouter switch failed: \(error.shortDescription, privacy: .private(mask: .hash))"
            )
            let mapped = SubrouterSwitchError.commandFailed
            lastSwitchError = mapped
            throw mapped
        } catch {
            // Unknown errors never carry raw dumps into user-facing state.
            Self.logger.error(
                "Unexpected subrouter switch error: \(String(describing: error), privacy: .private(mask: .hash))"
            )
            let wrapped = SubrouterSwitchError.commandFailed
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
        do {
            let reload = try await client.reloadAccounts(endpoint: endpointAtSwitch)
            if !reload.ok {
                reloadWarning = String(
                    localized: "subrouter.error.reloadFailed",
                    defaultValue: "Daemon reload reported failure"
                )
            }
        } catch let error as SubrouterClientError {
            Self.logger.error(
                "Subrouter reload warning: \(error.shortDescription, privacy: .private(mask: .hash))"
            )
            reloadWarning = error.shortDescription
        } catch {
            Self.logger.error(
                "Unexpected subrouter reload warning: \(String(describing: error), privacy: .private(mask: .hash))"
            )
            reloadWarning = String(
                localized: "subrouter.error.unexpectedReload",
                defaultValue: "The daemon reload could not be confirmed."
            )
        }
        // Sessions stay out of the post-switch refresh: nothing that runs
        // after a switch reads them (the switch payload and UI are
        // usage-driven), and `/_subrouter/sessions` returns the daemon's
        // whole routing history — the pending state must not wait on that
        // transfer. Only the socket verbs that read sessions (`status`,
        // `sessions`) fetch them.
        await performFreshRefresh(
            reason: "switch",
            includingSessions: false,
            forceAfterInFlight: true
        )
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
        guard configuration.isEnabled else {
            throw SubrouterClientError.unsupported(
                description: "The subrouter integration is disabled."
            )
        }
        guard !configuration.isRemoteEndpoint else {
            throw SubrouterClientError.unsupported(
                description: "Account reload is only available for the local subrouter daemon."
            )
        }
        let result = try await client.reloadAccounts(endpoint: configuration.endpoint)
        // The reload verb's payload never reads sessions; skip the
        // whole-history transfer here too.
        await performFreshRefresh(
            reason: "reload",
            includingSessions: false,
            forceAfterInFlight: true
        )
        return result
    }

    /// Records a non-fatal warning on the snapshot (e.g. a reload failure
    /// after a successful on-disk switch).
    func recordWarning(_ description: String) {
        snapshot.lastErrorDescription = description
    }
}

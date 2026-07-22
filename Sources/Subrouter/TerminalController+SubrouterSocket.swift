import Foundation
import CmuxSubrouter

/// Handles `subrouter.*` socket methods backing `cmux subrouter`.
///
/// All verbs route through the app-owned ``SubrouterAppRuntime`` store — the
/// single owner of daemon interaction — so a CLI-triggered switch or reload
/// updates the Agents panel and footer switcher immediately. The bodies run
/// on the socket-worker lane (they await HTTP fetches and the `sr`
/// subprocess) and hop to the main actor only for store access. Only
/// token-free metadata crosses the socket.
extension TerminalController {
    private nonisolated static var subrouterDisabledError: TerminalController.V2CallResult {
        .err(
            code: "subrouter_disabled",
            message: String(
                localized: "socket.subrouter.disabled",
                defaultValue: "The subrouter integration is disabled. Enable it in Settings or set subrouter.enabled in ~/.config/cmux/cmux.json."
            ),
            data: nil
        )
    }

    nonisolated func socketWorkerSubrouterResponse(
        method: String,
        id: Any?,
        params: [String: Any]
    ) -> String {
        switch method {
        case "subrouter.status":
            return v2AsyncResultCall(id: id, timeoutSeconds: 30) {
                await Self.subrouterRefreshResult(requiresHealthyDaemon: false) { snapshot, configuration in
                    var payload = Self.subrouterStatusPayload(snapshot: snapshot)
                    payload["endpoint"] = configuration.endpoint.baseURL.absoluteString
                    payload["account_count"] = snapshot.usageStatuses.count
                    payload["attention_count"] = snapshot.attentionCount
                    payload["session_count"] = snapshot.sessions.count
                    return payload
                }
            }
        case "subrouter.accounts":
            return v2AsyncResultCall(id: id, timeoutSeconds: 30) {
                await Self.subrouterRefreshResult(requiresHealthyDaemon: true) { snapshot, _ in
                    ["accounts": snapshot.usageStatuses.map { Self.subrouterAccountPayload($0, includeWindows: false) }]
                }
            }
        case "subrouter.usage":
            return v2AsyncResultCall(id: id, timeoutSeconds: 30) {
                await Self.subrouterRefreshResult(requiresHealthyDaemon: true) { snapshot, _ in
                    ["accounts": snapshot.usageStatuses.map { Self.subrouterAccountPayload($0, includeWindows: true) }]
                }
            }
        case "subrouter.sessions":
            return v2AsyncResultCall(id: id, timeoutSeconds: 30) {
                await Self.subrouterRefreshResult(requiresHealthyDaemon: true) { snapshot, _ in
                    ["sessions": snapshot.sessions.map(Self.subrouterSessionPayload)]
                }
            }
        case "subrouter.switch":
            guard let providerRaw = Self.subrouterString(params["provider"]),
                  let accountID = Self.subrouterString(params["account"]) else {
                return v2Error(
                    id: id,
                    code: "invalid_params",
                    message: "subrouter.switch requires `provider` (codex|claude) and `account`."
                )
            }
            return v2AsyncResultCall(id: id, timeoutSeconds: 90) {
                await Self.subrouterSwitchResult(providerRaw: providerRaw, accountID: accountID)
            }
        case "subrouter.reload":
            return v2AsyncResultCall(id: id, timeoutSeconds: 30) {
                await Self.subrouterReloadResult()
            }
        default:
            return v2Error(id: id, code: "method_not_found", message: "Unknown method")
        }
    }

    // MARK: - Store access

    /// Refreshes through the shared store (single-flight with UI polling)
    /// and shapes a success payload from the fresh snapshot. Returns the
    /// disabled error when the master gate is off.
    ///
    /// Socket verbs are an authoritative boundary, so the runtime re-reads
    /// sr's server registry first: `sr server use` inside a cmux terminal
    /// never deactivates the app, and these commands must answer for the
    /// registry's current server.
    ///
    /// - Parameter requiresHealthyDaemon: Data verbs (`accounts`, `usage`,
    ///   `sessions`) pass `true` so an unreachable daemon becomes an error
    ///   instead of silently serving retained (stale or empty) snapshot
    ///   data; `status` passes `false` because reporting the failure state
    ///   is its job.
    private nonisolated static func subrouterRefreshResult(
        requiresHealthyDaemon: Bool,
        _ payload: @Sendable (SubrouterSnapshot, SubrouterConfiguration) -> [String: Any]
    ) async -> TerminalController.V2CallResult {
        let runtime = await MainActor.run { SubrouterAppRuntime.shared }
        await runtime.refreshServerSelectionAndApply()
        let store = await MainActor.run { runtime.store }
        let configuration = await MainActor.run { store.configuration }
        guard configuration.isEnabled else { return Self.subrouterDisabledError }
        let snapshot = await store.performFreshRefresh(reason: "socket")
        if requiresHealthyDaemon, !snapshot.daemonState.isHealthy {
            return .err(
                code: "daemon_unreachable",
                message: snapshot.lastErrorDescription ?? "The subrouter daemon is unreachable.",
                data: nil
            )
        }
        return .ok(payload(snapshot, configuration))
    }

    private nonisolated static func subrouterSwitchResult(
        providerRaw: String,
        accountID: String
    ) async -> TerminalController.V2CallResult {
        let runtime = await MainActor.run { SubrouterAppRuntime.shared }
        // Re-read sr's registry first: the store's remote-server guard must
        // evaluate against the registry's current selection, not a cache
        // from the last activation.
        await runtime.refreshServerSelectionAndApply()
        let store = await MainActor.run { runtime.store }
        do {
            try await store.switchAccount(
                provider: SubrouterProvider(rawValue: providerRaw.lowercased()),
                accountID: accountID
            )
        } catch let error as SubrouterSwitchError {
            return Self.subrouterSwitchError(error)
        } catch {
            // Unknown errors stay generic: raw dumps never cross the
            // socket/CLI boundary (typed errors are mapped above).
            return .err(
                code: "sr_failed",
                message: "The account switch failed unexpectedly (\(type(of: error))).",
                data: nil
            )
        }
        let snapshot = await MainActor.run { store.snapshot }
        var payload: [String: Any] = [
            "switched": true,
            "provider": providerRaw.lowercased(),
            "account": accountID,
        ]
        if let warning = snapshot.lastErrorDescription {
            payload["warning"] = warning
        }
        return .ok(payload)
    }

    private nonisolated static func subrouterReloadResult() async -> TerminalController.V2CallResult {
        let store = await MainActor.run { SubrouterAppRuntime.shared.store }
        let enabled = await MainActor.run { store.configuration.isEnabled }
        guard enabled else { return Self.subrouterDisabledError }
        do {
            let result = try await store.reloadDaemonAccounts()
            return .ok([
                "ok": result.ok,
                "accounts": result.accounts,
                "usage_refreshed": result.usageRefreshed,
            ])
        } catch let error as SubrouterClientError {
            return .err(code: "daemon_unreachable", message: error.shortDescription, data: nil)
        } catch {
            return .err(
                code: "daemon_unreachable",
                message: "Could not reach the subrouter daemon (\(type(of: error))).",
                data: nil
            )
        }
    }

    private nonisolated static func subrouterSwitchError(_ error: SubrouterSwitchError) -> TerminalController.V2CallResult {
        switch error {
        case .integrationDisabled:
            return Self.subrouterDisabledError
        case .switchUnsupported(let provider):
            return .err(
                code: "unsupported_provider",
                message: "Provider '\(provider.rawValue)' has no switch support; use codex or claude.",
                data: nil
            )
        case .commandNotFound:
            return .err(
                code: "sr_not_found",
                message: "The sr CLI was not found on PATH or in ~/bin. Install subrouter or set subrouter.commandPath.",
                data: nil
            )
        case .commandFailed(let description):
            return .err(code: "sr_failed", message: description, data: nil)
        case .commandTimedOut:
            return .err(code: "sr_timeout", message: "The sr CLI timed out.", data: nil)
        case .switchAlreadyInFlight:
            return .err(code: "switch_in_flight", message: "Another account switch is already in progress.", data: nil)
        case .remoteServerManagesSelection(let serverName):
            return .err(
                code: "remote_server_selection",
                message: "Server '\(serverName)' assigns accounts per session automatically; there is no global switch. Use SUBROUTER_CODEX_ACCOUNT_ID to force an account for one session.",
                data: nil
            )
        }
    }

    // MARK: - Payload shaping (pure value mapping)

    // ISO8601DateFormatter is Apple-documented thread-safe; shared so the
    // per-session payload mapping does not allocate one per element.
    private nonisolated(unsafe) static let subrouterTimestampFormatter = ISO8601DateFormatter()

    private nonisolated static func subrouterStatusPayload(snapshot: SubrouterSnapshot) -> [String: Any] {
        var daemon: [String: Any] = [:]
        switch snapshot.daemonState {
        case .unknown:
            daemon["state"] = "unknown"
        case .healthy:
            daemon["state"] = "healthy"
        case .unreachable(let consecutiveFailures):
            daemon["state"] = "unreachable"
            daemon["consecutive_failures"] = consecutiveFailures
        }
        var payload: [String: Any] = ["enabled": true, "daemon": daemon]
        if let lastError = snapshot.lastErrorDescription {
            payload["last_error"] = lastError
        }
        if let lastUpdatedAt = snapshot.lastUpdatedAt {
            payload["last_updated"] = Self.subrouterTimestampFormatter.string(from: lastUpdatedAt)
        }
        return payload
    }

    private nonisolated static func subrouterAccountPayload(
        _ account: SubrouterAccountUsageStatus,
        includeWindows: Bool
    ) -> [String: Any] {
        var payload: [String: Any] = [
            "id": account.id,
            "provider": account.provider.rawValue,
            "auth_mode": account.authMode.rawValue,
            "active": account.isActive,
            "auth_checked": account.authChecked,
            "auth_valid": account.authValid,
            "needs_attention": account.needsAttention,
            "quota": Self.subrouterQuotaString(account.quotaAssessment),
        ]
        if let email = account.email { payload["email"] = email }
        if let planType = account.planType { payload["plan_type"] = planType }
        if let errorDescription = account.errorDescription { payload["error"] = errorDescription }
        if includeWindows {
            payload["windows"] = account.windows.map { window in
                [
                    "name": window.name,
                    "used_percent": window.usedPercent,
                    "limit_window_seconds": window.limitWindowSeconds,
                    "reset_after_seconds": window.resetAfterSeconds,
                    "feature": window.feature,
                ] as [String: Any]
            }
            if let credits = account.credits {
                payload["credits"] = [
                    "has_credits": credits.hasCredits,
                    "unlimited": credits.unlimited,
                    "balance": credits.balance,
                ] as [String: Any]
            }
        }
        return payload
    }

    private nonisolated static func subrouterSessionPayload(_ session: SubrouterSessionAssignment) -> [String: Any] {
        var payload: [String: Any] = [
            "agent_type": session.agentType,
            "session_id": session.sessionID,
            "account_id": session.accountID,
            "created_at": Self.subrouterTimestampFormatter.string(from: session.createdAt),
            "updated_at": Self.subrouterTimestampFormatter.string(from: session.updatedAt),
        ]
        if let userEmail = session.userEmail { payload["user_email"] = userEmail }
        return payload
    }

    private nonisolated static func subrouterQuotaString(_ assessment: SubrouterQuotaAssessment) -> String {
        switch assessment {
        case .ok: return "ok"
        case .tempCooked: return "temp_cooked"
        case .cooked: return "cooked"
        }
    }

    private nonisolated static func subrouterString(_ raw: Any?) -> String? {
        guard let value = raw as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

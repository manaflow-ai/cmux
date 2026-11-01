import CmuxControlSocket
import Foundation

extension TerminalController {
    /// `claude_account.switch`: moves a local Claude pane to another registered account and
    /// resumes its conversation there, through the same
    /// ``Workspace/switchClaudeAccount(panelId:toAccountNamed:trigger:)`` the terminal menu and
    /// the command palette run.
    ///
    /// Runs on the socket worker: the switch awaits transcript copies, the old Claude's exit and
    /// the new shell's prompt, and suspends on the main actor instead of holding it. It never
    /// activates the app or selects anything; the respawn keeps in-app focus where it was.
    /// Relayed requests are refused, because the switch respawns a local terminal and types a
    /// command into it.
    nonisolated func claudeAccountSwitchResponse(_ request: ControlRequest) async throws -> String {
        var accountName = ""
        if case .string(let rawAccount)? = request.params["account"] {
            accountName = rawAccount.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !accountName.isEmpty else {
            return Self.v2Encoder.error(
                id: request.id,
                code: "invalid_params",
                message: String(
                    localized: "socket.claudeAccountSwitch.accountRequired",
                    defaultValue: "Missing or invalid account"
                )
            )
        }
        let force: Bool
        switch request.params["force"] {
        case nil, .null?:
            force = false
        case .bool(let value)?:
            force = value
        default:
            return Self.v2Encoder.error(
                id: request.id,
                code: "invalid_params",
                message: String(
                    localized: "socket.claudeAccountSwitch.forceNotBoolean",
                    defaultValue: "force must be true or false"
                )
            )
        }

        // A destructive method never falls back to whichever pane happens to be focused.
        switch request.params["surface_id"] {
        case nil, .null?:
            return Self.v2Encoder.error(
                id: request.id,
                code: "invalid_params",
                message: String(
                    localized: "socket.claudeAccountSwitch.surfaceRequired",
                    defaultValue: "Missing surface_id"
                )
            )
        default:
            break
        }

        // Refs (`surface:3`) resolve on the main actor; one bounded hop keeps the socket worker
        // from blocking on the main queue.
        let target = try await v2MainAsync { () -> Result<ClaudeAccountSwitchTarget, ClaudeAccountSwitchTargetError> in
            self.claudeAccountSwitchTarget(request)
        }
        switch target {
        case .failure(let failure):
            return Self.v2Encoder.response(id: request.id, failure.result)
        case .success(let resolved):
            let outcome = await claudeAccountSwitchOutcome(
                workspaceId: resolved.workspaceId,
                panelId: resolved.panelId,
                accountName: accountName,
                force: force
            )
            guard let outcome else {
                return Self.v2Encoder.response(id: request.id, Self.claudeAccountSwitchSurfaceNotFound)
            }
            return Self.v2Encoder.response(
                id: request.id,
                outcome.controlCallResult(surfaceId: resolved.panelId, requestedAccountName: accountName)
            )
        }
    }

    struct ClaudeAccountSwitchTarget: Sendable {
        let workspaceId: UUID
        let panelId: UUID
    }

    struct ClaudeAccountSwitchTargetError: Error, Sendable {
        let result: ControlCallResult
    }

    private nonisolated static var claudeAccountSwitchSurfaceNotFound: ControlCallResult {
        .err(
            code: "not_found",
            message: String(
                localized: "socket.surfaceSelection.surfaceNotFound",
                defaultValue: "Surface not found for the given surface selector."
            ),
            data: nil
        )
    }

    /// The pane named by the required `surface_id` (a UUID or ref), in the workspace
    /// `workspace_id` names when present. A `workspace_id` or `surface_id` that names nothing
    /// is `not_found`, never ignored.
    private func claudeAccountSwitchTarget(
        _ request: ControlRequest
    ) -> Result<ClaudeAccountSwitchTarget, ClaudeAccountSwitchTargetError> {
        if let relayError = controlRemoteRelayDispatchError(method: request.method, params: request.params) {
            return .failure(ClaudeAccountSwitchTargetError(result: relayError))
        }
        v2RefreshKnownRefs()
        let params = request.params.mapValues(\.foundationObject)
        let workspaceNotFound = ClaudeAccountSwitchTargetError(result: .err(
            code: "not_found",
            message: String(
                localized: "socket.surfaceSelection.workspaceNotFound",
                defaultValue: "Workspace not found."
            ),
            data: nil
        ))
        if v2HasNonNullParam(params, "workspace_id"), v2UUIDAny(params["workspace_id"]) == nil {
            return .failure(workspaceNotFound)
        }
        guard let panelId = v2UUIDAny(params["surface_id"]) else {
            return .failure(ClaudeAccountSwitchTargetError(result: Self.claudeAccountSwitchSurfaceNotFound))
        }
        guard let tabManager = v2ResolveTabManager(params: params),
              let workspace = v2ResolveWorkspace(params: params, tabManager: tabManager) else {
            return .failure(v2HasNonNullParam(params, "workspace_id")
                ? workspaceNotFound
                : ClaudeAccountSwitchTargetError(result: Self.claudeAccountSwitchSurfaceNotFound))
        }
        guard workspace.panels[panelId] != nil else {
            return .failure(ClaudeAccountSwitchTargetError(result: Self.claudeAccountSwitchSurfaceNotFound))
        }
        return .success(ClaudeAccountSwitchTarget(workspaceId: workspace.id, panelId: panelId))
    }

    /// Checks the request against the pane (``ClaudeAccountSwitchSocketPreflight``), then runs
    /// the shared switch. `nil` when the pane is gone. Claude mid-response needs `force`, the
    /// socket's answer to the confirmation the menu asks for. A switch whose resume was never
    /// typed also posts a notification on the pane, because the caller may have been running
    /// in that very pane and died with the respawn.
    private func claudeAccountSwitchOutcome(
        workspaceId: UUID,
        panelId: UUID,
        accountName: String,
        force: Bool
    ) async -> ClaudeAccountSwitchSocketOutcome? {
        guard let workspace = AppDelegate.shared?.workspaceFor(tabId: workspaceId),
              workspace.panels[panelId] != nil else {
            return nil
        }
        let preflight = ClaudeAccountSwitchSocketPreflight(
            accountName: accountName,
            target: workspace.claudeAccountRegistry(forPanelId: panelId).account(named: accountName),
            current: workspace.currentClaudeAccount(panelId: panelId),
            runsOnAnotherMachine: workspace.terminalRunsOnAnotherMachine(panelId),
            responseRunning: workspace.isClaudeResponseRunning(panelId: panelId),
            force: force,
            homeDirectory: NSHomeDirectory()
        )
        if let refusal = preflight.refusal { return refusal }
        let outcome = ClaudeAccountSwitchSocketOutcome.finished(await workspace.switchClaudeAccount(
            panelId: panelId,
            toAccountNamed: accountName,
            trigger: .manual
        ))
        let paneIsLive = AppDelegate.shared?.agentNotificationDeliveryTarget(
            claimedTabId: workspaceId,
            surfaceId: panelId
        ) != nil
        outcome.resumeNotification?.post(
            workspaceId: workspaceId,
            panelId: panelId,
            paneIsLive: paneIsLive
        ) { tabId, surfaceId, title, subtitle, body in
            deliverNotificationSynchronously(
                tabId: tabId,
                surfaceId: surfaceId,
                title: title,
                subtitle: subtitle,
                body: body
            )
        }
        return outcome
    }
}

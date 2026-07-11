// Claude hook workspace routing resolution: route to the originating workspace, never the focused tab.

import Foundation

extension CMUXCLI {
    typealias CallerTerminalBindingResolution = (
        binding: CallerTerminalBinding?,
        isAmbiguous: Bool
    )

    /// Resolve the workspace a Claude hook should mutate. Unresolved caller-TTY
    /// ambiguity fails closed before any implicit candidate; otherwise priority is
    /// the recorded/preferred workspace, caller binding, live ambient workspace,
    /// then caller binding. Each candidate is validated against a live workspace.
    ///
    /// Returns `nil` when the caller cannot be positively identified. It deliberately
    /// does NOT fall back to `workspace.current` (the focused tab): routing a
    /// background agent's status/notification/summary to whatever tab happens to be
    /// focused mis-delivers it onto an unrelated session (this mirrors the generic
    /// agent hook, which already no-ops instead of guessing). Callers treat `nil` as a
    /// no-op rather than mutating an arbitrary workspace.
    func resolvePreferredWorkspaceIdForClaudeHook(
        preferred: String?,
        fallback: String?,
        preferCallerTTYOverFallback: Bool = false,
        callerTerminalBinding: (() -> CallerTerminalBindingResolution)? = nil,
        client: SocketClient
    ) throws -> String? {
        // With no explicit routing flags, unresolved TTY ambiguity invalidates
        // every ambient or stored candidate. PID recovery is folded into the
        // provider first and clears isAmbiguous when it proves one live pane.
        if preferCallerTTYOverFallback,
           callerTerminalBinding?().isAmbiguous == true {
            return nil
        }
        if let preferred = nonEmptyClaudeHookIdentifier(preferred),
           let resolved = strictClaudeHookWorkspaceId(preferred, client: client) {
            return resolved
        }
        if preferCallerTTYOverFallback,
           let callerWorkspaceId = uniqueCallerWorkspaceIdForClaudeHook(
               callerTerminalBinding: callerTerminalBinding,
               client: client
           ) {
            return callerWorkspaceId
        }
        if let fallback = nonEmptyClaudeHookIdentifier(fallback),
           let resolved = strictClaudeHookWorkspaceId(fallback, client: client) {
            return resolved
        }
        return uniqueCallerWorkspaceIdForClaudeHook(
            callerTerminalBinding: callerTerminalBinding,
            client: client
        )
    }

    /// Resolve `raw` to a workspace id only when that workspace currently exists.
    func strictClaudeHookWorkspaceId(_ raw: String, client: SocketClient) -> String? {
        // UUID identities (hook session records, live CMUX_WORKSPACE_ID) validate directly.
        if isUUID(raw) {
            return claudeHookWorkspaceExists(raw, client: client) ? raw : nil
        }
        // Explicit non-UUID selectors (handle refs like "workspace:1", numeric indexes —
        // both documented for --workspace) resolve strictly. `resolveWorkspaceId` fails
        // closed for every non-blank selector, and `raw` is non-blank here (callers pass
        // it through `nonEmptyClaudeHookIdentifier`), so the focused-tab fallback inside
        // `resolveWorkspaceId` is structurally unreachable and the "never fall back to
        // focused" invariant holds.
        guard let resolved = try? resolveWorkspaceId(raw, client: client),
              isUUID(resolved),
              claudeHookWorkspaceExists(resolved, client: client) else {
            return nil
        }
        return resolved
    }

    func claudeHookWorkspaceExists(_ workspaceId: String, client: SocketClient) -> Bool {
        (try? client.sendV2(method: "surface.list", params: ["workspace_id": workspaceId])) != nil
    }

    /// Caller-TTY binding that refuses ambiguous TTY matches: returns a binding only
    /// when every `debug.terminals` entry for the caller's TTY name agrees on a single
    /// workspace and surface (macOS reuses `ttysNNN` names, and stale entries can
    /// shadow live ones). PID-derived bindings don't need this guard because a PID
    /// lives in exactly one surface.
    func uniqueCallerTerminalBindingByTTY(
        client: SocketClient,
        includeAmbientTTY: Bool = true
    ) -> CallerTerminalBinding? {
        callerTerminalBindingResolutionByTTY(
            client: client,
            includeAmbientTTY: includeAmbientTTY
        ).binding
    }

    func callerTerminalBindingResolutionByTTY(
        client: SocketClient,
        includeAmbientTTY: Bool = true
    ) -> CallerTerminalBindingResolution {
        guard let ttyName = resolveCallerTTYName(includeAmbientTTY: includeAmbientTTY),
              let payload = try? client.sendV2(method: "debug.terminals") else {
            return CallerTerminalBindingResolution(binding: nil, isAmbiguous: false)
        }
        let terminals = payload["terminals"] as? [[String: Any]] ?? []
        var matched: [CallerTerminalBinding] = []
        for terminal in terminals {
            guard normalizedTTYName(terminal["tty"] as? String) == ttyName,
                  let workspaceId = normalizedHandleValue(terminal["workspace_id"] as? String),
                  let surfaceId = normalizedHandleValue(terminal["surface_id"] as? String) else {
                continue
            }
            matched.append(CallerTerminalBinding(workspaceId: workspaceId, surfaceId: surfaceId))
        }
        guard let first = matched.first else {
            return CallerTerminalBindingResolution(binding: nil, isAmbiguous: false)
        }
        guard matched.allSatisfy({ $0.workspaceId == first.workspaceId && $0.surfaceId == first.surfaceId }) else {
            return CallerTerminalBindingResolution(binding: nil, isAmbiguous: true)
        }
        return CallerTerminalBindingResolution(binding: first, isAmbiguous: false)
    }

    func independentlyValidatedMappedTerminalBinding(
        _ mapped: ClaudeHookSessionRecord?,
        client: SocketClient
    ) -> CallerTerminalBinding? {
        guard let mapped,
              let binding = resolveAgentProcessTerminalBinding(pid: mapped.pid, client: client),
              normalizedHandleValue(mapped.workspaceId) == normalizedHandleValue(binding.workspaceId),
              normalizedHandleValue(mapped.surfaceId) == normalizedHandleValue(binding.surfaceId) else {
            return nil
        }
        return binding
    }

    /// Like `resolveCallerWorkspaceIdForClaudeHook`, but refuses to guess when the
    /// caller's TTY name maps to more than one workspace. macOS reuses `ttysNNN`
    /// device names across panes/sessions, so a first-match on a shared name would
    /// route to an arbitrary sibling session. The provider preserves positive
    /// ambiguity after PID recovery fails, so ambient fallbacks can fail closed.
    func uniqueCallerWorkspaceIdForClaudeHook(
        callerTerminalBinding: (() -> CallerTerminalBindingResolution)?,
        client: SocketClient
    ) -> String? {
        if let callerTerminalBinding {
            let resolution = callerTerminalBinding()
            guard !resolution.isAmbiguous,
                  let binding = resolution.binding,
                  claudeHookSurfaceIsListed(binding.surfaceId, workspaceId: binding.workspaceId, client: client) else {
                return nil
            }
            return binding.workspaceId
        }
        guard let ttyName = resolveCallerTTYName(),
              let payload = try? client.sendV2(method: "debug.terminals") else {
            return nil
        }
        let terminals = payload["terminals"] as? [[String: Any]] ?? []
        var matchedWorkspaces: Set<String> = []
        for terminal in terminals {
            guard normalizedTTYName(terminal["tty"] as? String) == ttyName,
                  let workspaceId = normalizedHandleValue(terminal["workspace_id"] as? String) else {
                continue
            }
            matchedWorkspaces.insert(workspaceId)
        }
        guard matchedWorkspaces.count == 1,
              let only = matchedWorkspaces.first,
              claudeHookWorkspaceExists(only, client: client) else {
            return nil
        }
        return only
    }

    func nonEmptyClaudeHookIdentifier(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

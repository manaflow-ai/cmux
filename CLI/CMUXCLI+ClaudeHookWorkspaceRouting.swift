// Claude hook workspace routing resolution: route to the originating workspace, never the focused tab.

import Foundation

extension CMUXCLI {
    /// Resolve the workspace a Claude hook should mutate, in strict priority order:
    /// the recorded/preferred workspace, an unambiguous caller-TTY binding (only when
    /// `preferCallerTTYOverFallback`), the live `CMUX_WORKSPACE_ID` fallback, then an
    /// unambiguous caller-TTY binding. Each candidate is validated against a live
    /// workspace before it is accepted.
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
        callerTerminalBinding: (() -> CallerTerminalBinding?)? = nil,
        client: SocketClient
    ) throws -> String? {
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
        // Only trust UUID identities. `resolveWorkspaceId` falls through to
        // `workspace.current` (the focused tab) for any input that isn't a UUID,
        // handle ref, or numeric index — which would structurally reintroduce the
        // focused-tab misroute this resolver exists to prevent (e.g. a non-UUID
        // CMUX_WORKSPACE_ID). Hook identities are always workspace UUIDs, so this
        // costs nothing and enforces the "never fall back to focused" invariant.
        guard isUUID(raw), claudeHookWorkspaceExists(raw, client: client) else {
            return nil
        }
        return raw
    }

    func claudeHookWorkspaceExists(_ workspaceId: String, client: SocketClient) -> Bool {
        (try? client.sendV2(method: "surface.list", params: ["workspace_id": workspaceId])) != nil
    }

    /// Like `resolveCallerWorkspaceIdForClaudeHook`, but refuses to guess when the
    /// caller's TTY name maps to more than one workspace. macOS reuses `ttysNNN`
    /// device names across panes/sessions, so a first-match on a shared name would
    /// route to an arbitrary sibling session. A PID/closure-provided binding is
    /// authoritative (unique by construction) and used directly.
    func uniqueCallerWorkspaceIdForClaudeHook(
        callerTerminalBinding: (() -> CallerTerminalBinding?)?,
        client: SocketClient
    ) -> String? {
        if let callerTerminalBinding {
            guard let binding = callerTerminalBinding(),
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

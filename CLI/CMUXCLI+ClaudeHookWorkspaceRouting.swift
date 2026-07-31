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
    /// shadow live ones).
    /// PID-derived bindings don't need this guard — a PID lives in exactly one surface.
    func uniqueCallerTerminalBindingByTTY(
        client: SocketClient,
        includeAmbientTTY: Bool = true
    ) -> CallerTerminalBinding? {
        guard let ttyName = resolveCallerTTYName(includeAmbientTTY: includeAmbientTTY),
              let payload = try? client.sendV2(method: "debug.terminals") else {
            return nil
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
        guard let first = matched.first,
              matched.allSatisfy({ $0.workspaceId == first.workspaceId && $0.surfaceId == first.surfaceId }) else {
            return nil
        }
        return first
    }

    /// Like `resolveCallerWorkspaceIdForClaudeHook`, but refuses to guess when the
    /// caller's TTY name maps to more than one workspace. macOS reuses `ttysNNN`
    /// device names across panes/sessions, so a first-match on a shared name would
    /// route to an arbitrary sibling session. The provider closure yields only
    /// unambiguous-TTY or PID-derived bindings, so it is trusted directly.
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

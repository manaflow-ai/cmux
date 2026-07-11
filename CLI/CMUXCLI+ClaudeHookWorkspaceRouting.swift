// Claude hook workspace routing resolution: route to the originating workspace, never the focused tab.

import Foundation

extension CMUXCLI {
    struct CallerTerminalBindingResolution {
        let binding: CallerTerminalBinding?
        let isAmbiguous: Bool
        let usedTargetedResolver: Bool

        init(
            binding: CallerTerminalBinding?,
            isAmbiguous: Bool,
            usedTargetedResolver: Bool = false
        ) {
            self.binding = binding
            self.isAmbiguous = isAmbiguous
            self.usedTargetedResolver = usedTargetedResolver
        }
    }

    func claudeCallerTerminalBindingProvider(
        preferCallerTTYRouting: Bool,
        workspaceFallback: String?,
        surfaceFallback: String?,
        client: SocketClient
    ) -> (() -> CallerTerminalBindingResolution)? {
        guard preferCallerTTYRouting else { return nil }
        var cached: CallerTerminalBindingResolution?
        return {
            if let cached { return cached }
            let resolution = callerTerminalBindingResolutionByTTY(
                client: client,
                includeAmbientTTY: workspaceFallback == nil && surfaceFallback == nil,
                pid: claudeAgentPID(from: ProcessInfo.processInfo.environment),
                allowDiagnosticFallback: false
            )
            let binding = resolution.binding.flatMap {
                claudeHookSurfaceIsListed($0.surfaceId, workspaceId: $0.workspaceId, client: client) ? $0 : nil
            }
            let validated = CallerTerminalBindingResolution(
                binding: binding,
                isAmbiguous: resolution.isAmbiguous || (resolution.binding != nil && binding == nil),
                usedTargetedResolver: true
            )
            cached = validated
            return validated
        }
    }

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
        preferredSurface: String? = nil,
        fallback: String?,
        preferCallerTTYOverFallback: Bool = false,
        callerTerminalBinding: (() -> CallerTerminalBindingResolution)? = nil,
        client: SocketClient
    ) throws -> String? {
        if let preferred = nonEmptyClaudeHookIdentifier(preferred),
           let resolved = strictClaudeHookWorkspaceId(preferred, client: client) {
            guard preferCallerTTYOverFallback else { return resolved }
            // The targeted resolver uses a short-lived app-side process cache,
            // so every implicit mapped hook can reject a stale binding without
            // paying for `debug.terminals` or a `system.top` process tree.
            if let resolution = callerTerminalBinding?() {
                guard !resolution.isAmbiguous else { return nil }
                if let binding = resolution.binding {
                    guard normalizedHandleValue(binding.workspaceId) == normalizedHandleValue(resolved),
                          claudeHookSurfaceIsListed(
                              binding.surfaceId,
                              workspaceId: binding.workspaceId,
                              client: client
                          ) else {
                        return nil
                    }
                    if let preferredSurface = nonEmptyClaudeHookIdentifier(preferredSurface),
                       claudeHookSurfaceIsListed(preferredSurface, workspaceId: resolved, client: client),
                       normalizedHandleValue(preferredSurface) != normalizedHandleValue(binding.surfaceId) {
                        return nil
                    }
                }
            }
            return resolved
        }
        if preferCallerTTYOverFallback,
           let callerWorkspaceId = uniqueCallerWorkspaceIdForClaudeHook(
               callerTerminalBinding: callerTerminalBinding,
               client: client
           ) {
            return callerWorkspaceId
        }
        if preferCallerTTYOverFallback,
           callerTerminalBinding?().isAmbiguous == true {
            return nil
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
        includeAmbientTTY: Bool = true,
        pid: Int? = nil,
        allowDiagnosticFallback: Bool = true
    ) -> CallerTerminalBindingResolution {
        let ttyName = resolveCallerTTYName(includeAmbientTTY: includeAmbientTTY)
        var targetedParams: [String: Any] = [:]
        if let ttyName { targetedParams["tty_name"] = ttyName }
        if let pid, pid > 0 { targetedParams["pid"] = pid }
        if !targetedParams.isEmpty,
           let payload = try? client.sendV2(method: "system.resolve_terminal", params: targetedParams) {
            if let resolution = targetedCallerTerminalBindingResolution(payload) {
                return resolution
            }
        }
        if !allowDiagnosticFallback {
            return CallerTerminalBindingResolution(
                binding: nil,
                isAmbiguous: !targetedParams.isEmpty,
                usedTargetedResolver: true
            )
        }

        guard let ttyName,
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

    private func targetedCallerTerminalBindingResolution(
        _ payload: [String: Any]
    ) -> CallerTerminalBindingResolution? {
        guard let rawTTYBindings = payload["tty_bindings"] as? [Any],
              payload.keys.contains("pid_binding"),
              payload["pid_binding"] is NSNull || payload["pid_binding"] is [String: Any] else {
            return nil
        }
        func binding(_ value: Any?) -> CallerTerminalBinding? {
            guard let object = value as? [String: Any],
                  let workspaceId = normalizedHandleValue(object["workspace_id"] as? String),
                  let surfaceId = normalizedHandleValue(object["surface_id"] as? String) else {
                return nil
            }
            return CallerTerminalBinding(workspaceId: workspaceId, surfaceId: surfaceId)
        }
        func same(_ lhs: CallerTerminalBinding, _ rhs: CallerTerminalBinding) -> Bool {
            normalizedHandleValue(lhs.workspaceId) == normalizedHandleValue(rhs.workspaceId)
                && normalizedHandleValue(lhs.surfaceId) == normalizedHandleValue(rhs.surfaceId)
        }

        var ttyBindings: [CallerTerminalBinding] = []
        for raw in rawTTYBindings {
            guard let candidate = binding(raw) else { return nil }
            guard !ttyBindings.contains(where: { same($0, candidate) }) else { continue }
            ttyBindings.append(candidate)
        }
        let pidBinding: CallerTerminalBinding?
        if payload["pid_binding"] is NSNull {
            pidBinding = nil
        } else {
            guard let decoded = binding(payload["pid_binding"]) else { return nil }
            pidBinding = decoded
        }
        if ttyBindings.count == 1, let ttyBinding = ttyBindings.first {
            if let pidBinding, !same(ttyBinding, pidBinding) {
                return CallerTerminalBindingResolution(
                    binding: nil,
                    isAmbiguous: true,
                    usedTargetedResolver: true
                )
            }
            return CallerTerminalBindingResolution(
                binding: ttyBinding,
                isAmbiguous: false,
                usedTargetedResolver: true
            )
        }
        if ttyBindings.count > 1 {
            let disambiguated = pidBinding.flatMap { pidBinding in
                ttyBindings.contains(where: { same($0, pidBinding) }) ? pidBinding : nil
            }
            return CallerTerminalBindingResolution(
                binding: disambiguated,
                isAmbiguous: disambiguated == nil,
                usedTargetedResolver: true
            )
        }
        return CallerTerminalBindingResolution(
            binding: pidBinding,
            isAmbiguous: false,
            usedTargetedResolver: true
        )
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

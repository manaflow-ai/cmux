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
            let resolution = liveHookCallerTerminalBindingResolution(
                client: client,
                includeAmbientTTY: client.isRelayBacked || (workspaceFallback == nil && surfaceFallback == nil),
                allowDiagnosticFallback: false
            )
            let binding = resolution.binding.flatMap {
                claudeHookSurfaceIsListed($0.surfaceId, workspaceId: $0.workspaceId, client: client) ? $0 : nil
            }
            let validated = CallerTerminalBindingResolution(
                binding: binding,
                isAmbiguous: resolution.isAmbiguous || binding == nil,
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
            // Every implicit mapped hook requires a positive live terminal
            // binding. Missing proof fails closed instead of accepting saved
            // or ambient identity.
            guard let resolution = callerTerminalBinding?(),
                  !resolution.isAmbiguous,
                  let binding = resolution.binding,
                  normalizedHandleValue(binding.workspaceId) == normalizedHandleValue(resolved),
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
            return resolved
        }
        if preferCallerTTYOverFallback {
            guard callerTerminalBinding != nil else { return nil }
            return uniqueCallerWorkspaceIdForClaudeHook(
               callerTerminalBinding: callerTerminalBinding,
               client: client
            )
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
        // Relay-backed hooks carry a PID from the remote host's namespace. It
        // cannot prove ownership in the local process table, so remote routing
        // relies on the relay-reported TTY/ambient binding instead.
        let locallyResolvablePID = client.isRelayBacked ? nil : pid
        var targetedParams: [String: Any] = [:]
        if let ttyName { targetedParams["tty_name"] = ttyName }
        if let locallyResolvablePID, locallyResolvablePID > 0 {
            targetedParams["pid"] = locallyResolvablePID
        }
        if !targetedParams.isEmpty,
           let payload = try? client.sendV2(method: "system.resolve_terminal", params: targetedParams) {
            if let resolution = targetedCallerTerminalBindingResolution(
                payload,
                requirePIDBinding: locallyResolvablePID != nil
            ) {
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
        if let locallyResolvablePID {
            guard let pidBinding = resolveAgentProcessTerminalBinding(
                pid: locallyResolvablePID,
                client: client
            ),
                  normalizedHandleValue(pidBinding.workspaceId) == normalizedHandleValue(first.workspaceId),
                  normalizedHandleValue(pidBinding.surfaceId) == normalizedHandleValue(first.surfaceId) else {
                return CallerTerminalBindingResolution(binding: nil, isAmbiguous: true)
            }
        }
        return CallerTerminalBindingResolution(binding: first, isAmbiguous: false)
    }

    /// Resolve implicit hook ownership from the currently running CLI process.
    /// A local PID cannot be recycled while this request is in flight. Relay
    /// clients discard that host-local PID and use only relay-reported TTY data.
    func liveHookCallerTerminalBindingResolution(
        client: SocketClient,
        includeAmbientTTY: Bool = true,
        allowDiagnosticFallback: Bool = true
    ) -> CallerTerminalBindingResolution {
        callerTerminalBindingResolutionByTTY(
            client: client,
            includeAmbientTTY: includeAmbientTTY,
            pid: Int(ProcessInfo.processInfo.processIdentifier),
            allowDiagnosticFallback: allowDiagnosticFallback
        )
    }

    private func targetedCallerTerminalBindingResolution(
        _ payload: [String: Any],
        requirePIDBinding: Bool
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
        var ttyBindings: [CallerTerminalBinding] = []
        for raw in rawTTYBindings {
            guard let candidate = binding(raw) else { return nil }
            guard !ttyBindings.contains(where: {
                normalizedHandleValue($0.workspaceId) == normalizedHandleValue(candidate.workspaceId)
                    && normalizedHandleValue($0.surfaceId) == normalizedHandleValue(candidate.surfaceId)
            }) else { continue }
            ttyBindings.append(candidate)
        }
        if requirePIDBinding {
            guard let pidBinding = binding(payload["pid_binding"]) else {
                return CallerTerminalBindingResolution(
                    binding: nil,
                    isAmbiguous: true,
                    usedTargetedResolver: true
                )
            }
            return CallerTerminalBindingResolution(
                binding: pidBinding,
                isAmbiguous: false,
                usedTargetedResolver: true
            )
        }
        if ttyBindings.count == 1, let ttyBinding = ttyBindings.first {
            return CallerTerminalBindingResolution(
                binding: ttyBinding,
                isAmbiguous: false,
                usedTargetedResolver: true
            )
        }
        if ttyBindings.count > 1 {
            return CallerTerminalBindingResolution(
                binding: nil,
                isAmbiguous: true,
                usedTargetedResolver: true
            )
        }
        return CallerTerminalBindingResolution(
            binding: nil,
            isAmbiguous: false,
            usedTargetedResolver: true
        )
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

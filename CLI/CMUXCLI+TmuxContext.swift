import Foundation
import CMUXAgentLaunch
import CmuxFoundation
import CmuxSocketControl
import CoreFoundation
import CryptoKit
import Darwin
#if canImport(LocalAuthentication)
import LocalAuthentication
#endif
#if canImport(Security)
import Security
#endif
#if canImport(Sentry)
import Sentry
#endif


// MARK: - tmux compat target resolution and format context
extension CMUXCLI {
    func tmuxResolveWorkspaceTarget(_ raw: String?, client: SocketClient) throws -> String {
        guard var token = normalizedTmuxTarget(raw) else {
            if let callerWorkspace = tmuxCallerWorkspaceHandle() {
                return try resolveWorkspaceId(callerWorkspace, client: client)
            }
            return try resolveWorkspaceId(nil, client: client)
        }

        if token == "!" || token == "^" || token == "-" {
            let payload = try client.sendV2(method: "workspace.last")
            if let workspaceId = payload["workspace_id"] as? String {
                return workspaceId
            }
            throw CLIError(message: "Previous workspace not found")
        }

        if let dot = token.lastIndex(of: ".") {
            token = String(token[..<dot])
        }
        if let colon = token.lastIndex(of: ":") {
            let suffix = token[token.index(after: colon)...]
            token = suffix.isEmpty ? String(token[..<colon]) : String(suffix)
        }
        let selector = tmuxSelectorToken(token)
        let normalizedSelectorToken = selector.token

        if (!selector.sigiled || isUUID(normalizedSelectorToken)),
           let resolvedHandle = try? normalizeWorkspaceHandle(normalizedSelectorToken, client: client, allowCurrent: true) {
            return try resolveWorkspaceId(resolvedHandle, client: client)
        }

        if let workspaceId = try tmuxWorkspaceIdForCompatHandle(token, client: client) {
            return workspaceId
        }

        if selector.sigiled {
            throw CLIError(message: "Workspace target not found")
        }

        let needle = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let items = try tmuxWorkspaceItems(client: client)
        if let match = items.first(where: {
            (($0["title"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) == needle
        }), let id = match["id"] as? String {
            return id
        }

        throw CLIError(message: "Workspace target not found: \(token)")
    }

    func tmuxResolvePaneTarget(_ raw: String?, client: SocketClient) throws -> (workspaceId: String, paneId: String) {
        let paneSelector = tmuxPaneSelector(from: raw)
        let workspaceSelector = tmuxWindowSelector(from: raw)
        let workspaceId: String = {
            if let workspaceSelector {
                return (try? tmuxResolveWorkspaceTarget(workspaceSelector, client: client)) ?? ""
            }
            if let paneSelector,
               let callerWorkspaceId = tmuxResolvedCallerWorkspaceId(client: client),
               (try? tmuxCanonicalPaneId(paneSelector, workspaceId: callerWorkspaceId, client: client)) != nil {
                return callerWorkspaceId
            }
            if let paneSelector,
               let workspaceId = try? tmuxWorkspaceIdForPaneHandle(paneSelector, client: client) {
                return workspaceId
            }
            return (try? tmuxResolveWorkspaceTarget(nil, client: client)) ?? ""
        }()
        guard !workspaceId.isEmpty else {
            throw CLIError(message: "Workspace target not found")
        }
        let paneId: String
        if let paneSelector {
            paneId = try tmuxCanonicalPaneId(paneSelector, workspaceId: workspaceId, client: client)
        } else if tmuxResolvedCallerWorkspaceId(client: client) == workspaceId,
                  let callerPane = tmuxCallerPaneHandle(),
                  let callerPaneId = try? tmuxCanonicalPaneId(callerPane, workspaceId: workspaceId, client: client) {
            paneId = callerPaneId
        } else {
            paneId = try tmuxFocusedPaneId(workspaceId: workspaceId, client: client)
        }
        return (workspaceId, paneId)
    }

    func tmuxSelectedSurfaceId(
        workspaceId: String,
        paneId: String,
        client: SocketClient
    ) throws -> String {
        let payload = try client.sendV2(
            method: "pane.surfaces",
            params: ["workspace_id": workspaceId, "pane_id": paneId]
        )
        let surfaces = payload["surfaces"] as? [[String: Any]] ?? []
        if let selected = surfaces.first(where: { boolFromAny($0["selected"]) == true }),
           let id = selected["id"] as? String {
            return id
        }
        if let first = surfaces.first?["id"] as? String {
            return first
        }
        throw CLIError(message: "Pane has no surface to target")
    }

    func tmuxStoredStartCommand(
        workspaceId: String,
        surfaceId: String,
        client: SocketClient
    ) throws -> String? {
        let payload = try client.sendV2(method: "surface.list", params: ["workspace_id": workspaceId])
        let surfaces = payload["surfaces"] as? [[String: Any]] ?? []
        guard let surface = surfaces.first(where: { ($0["id"] as? String) == surfaceId }) else {
            return nil
        }
        return [
            surface["tmux_start_command"],
            surface["pane_start_command"],
            surface["initial_command"]
        ]
            .compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }

    func tmuxResolveSurfaceTarget(
        _ raw: String?,
        client: SocketClient
    ) throws -> (workspaceId: String, paneId: String?, surfaceId: String) {
        if tmuxPaneSelector(from: raw) != nil {
            let resolved = try tmuxResolvePaneTarget(raw, client: client)
            // When the target pane matches the caller's pane, prefer the caller's
            // exact surface (CMUX_SURFACE_ID) over the pane's currently selected
            // surface. The selected surface can change (e.g. tab switches) after
            // claude-teams started, but the caller surface stays fixed.
            let callerPane = tmuxCallerPaneHandle()
            let callerSurface = tmuxCallerSurfaceHandle()
            let canonicalCallerPane = callerPane.flatMap { try? tmuxCanonicalPaneId($0, workspaceId: resolved.workspaceId, client: client) }
            let paneMatch = callerPane != nil && (resolved.paneId == callerPane! || resolved.paneId == canonicalCallerPane)
            if paneMatch,
               let callerSurface,
               let surfaceId = try? tmuxCanonicalSurfaceId(
                    callerSurface,
                    workspaceId: resolved.workspaceId,
                    client: client
               ) {
                return (resolved.workspaceId, resolved.paneId, surfaceId)
            }
            let surfaceId = try tmuxSelectedSurfaceId(
                workspaceId: resolved.workspaceId,
                paneId: resolved.paneId,
                client: client
            )
            return (resolved.workspaceId, resolved.paneId, surfaceId)
        }

        let workspaceId = try tmuxResolveWorkspaceTarget(tmuxWindowSelector(from: raw), client: client)
        if tmuxWindowSelector(from: raw) == nil,
           tmuxResolvedCallerWorkspaceId(client: client) == workspaceId,
           let callerSurface = tmuxCallerSurfaceHandle(),
           let surfaceId = try? tmuxCanonicalSurfaceId(
                callerSurface,
                workspaceId: workspaceId,
                client: client
           ) {
            return (workspaceId, nil, surfaceId)
        }
        let surfaceId = try resolveSurfaceId(nil, workspaceId: workspaceId, client: client)
        return (workspaceId, nil, surfaceId)
    }

    func tmuxAnchoredSplitTarget(
        workspaceId: String,
        client: SocketClient
    ) -> (targetSurfaceId: String, callerSurfaceId: String?, direction: String)? {
        var store = loadTmuxCompatStore()
        if let lastColumn = store.mainVerticalLayouts[workspaceId]?.lastColumnSurfaceId {
            if let lastColumnId = try? tmuxCanonicalSurfaceId(
                lastColumn,
                workspaceId: workspaceId,
                client: client
            ) {
                // Once the agent column exists, keep stacking into it even if the
                // caller surface handle has churned from a stale surface:<n> ref.
                return (lastColumnId, nil, "down")
            }

            // Right-column anchors can outlive the pane they pointed at.
            // Drop stale state and rebuild from the caller surface instead.
            store.mainVerticalLayouts[workspaceId]?.lastColumnSurfaceId = nil
            store.lastSplitSurface.removeValue(forKey: workspaceId)
            try? saveTmuxCompatStore(store)
        }

        let candidateAnchors = [
            tmuxCallerSurfaceHandle(),
            store.mainVerticalLayouts[workspaceId]?.mainSurfaceId
        ].compactMap { $0 }
        for candidate in candidateAnchors {
            if let anchorSurfaceId = try? tmuxCanonicalSurfaceId(
                candidate,
                workspaceId: workspaceId,
                client: client
            ) {
                return (anchorSurfaceId, anchorSurfaceId, "right")
            }
        }

        let removedLayout = store.mainVerticalLayouts.removeValue(forKey: workspaceId) != nil
        let removedSplit = store.lastSplitSurface.removeValue(forKey: workspaceId) != nil
        if removedLayout || removedSplit {
            try? saveTmuxCompatStore(store)
        }
        return nil
    }

    func tmuxRenderFormat(
        _ format: String?,
        context: [String: String],
        fallback: String
    ) -> String {
        guard let format, !format.isEmpty else { return fallback }
        var rendered = format
        for (key, value) in context {
            rendered = rendered.replacingOccurrences(of: "#{\(key)}", with: value)
        }
        rendered = rendered.replacingOccurrences(
            of: "#\\{[^}]+\\}",
            with: "",
            options: .regularExpression
        )
        let trimmed = rendered.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }

    func tmuxFormatContext(
        workspaceId: String,
        paneId: String? = nil,
        surfaceId: String? = nil,
        client: SocketClient
    ) throws -> [String: String] {
        let canonicalWorkspaceId = try resolveWorkspaceId(workspaceId, client: client)
        var context: [String: String] = [
            "session_name": "cmux",
            "session_id": "$\(tmuxStableNumericId(canonicalWorkspaceId))",
            "session_attached": "1",
            "window_id": "@\(tmuxStableNumericId(canonicalWorkspaceId))",
            "window_uuid": canonicalWorkspaceId,
            "window_active": "0",
            "window_flags": "",
            "window_width": "80",
            "window_height": "24",
            "pane_active": "1",
            "pane_width": "80",
            "pane_height": "24",
            "pane_current_path": tmuxFallbackCurrentPath()
        ]
        let activeByCaller = tmuxResolvedCallerWorkspaceId(client: client) == canonicalWorkspaceId
        if activeByCaller {
            context["window_active"] = "1"
            context["window_flags"] = "*"
        }

        let workspaceItems = try tmuxWorkspaceItems(client: client)
        if let workspace = workspaceItems.first(where: {
            ($0["id"] as? String) == canonicalWorkspaceId || ($0["ref"] as? String) == workspaceId
        }) {
            if let index = intFromAny(workspace["index"]) {
                context["window_index"] = String(index)
            }
            if !activeByCaller, let active = boolFromAny(workspace["active"])
                ?? boolFromAny(workspace["focused"])
                ?? boolFromAny(workspace["selected"]) {
                context["window_active"] = active ? "1" : "0"
                context["window_flags"] = active ? "*" : ""
            }
            let title = ((workspace["title"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty {
                context["window_name"] = title
            }
            if let path = tmuxPathFromObject(workspace) {
                context["pane_current_path"] = path
            }
        }

        let currentPayload = try client.sendV2(method: "surface.current", params: ["workspace_id": canonicalWorkspaceId])
        let resolvedPaneId: String? = {
            if let paneId {
                return (try? tmuxCanonicalPaneId(paneId, workspaceId: canonicalWorkspaceId, client: client)) ?? paneId
            }
            if let currentPaneId = currentPayload["pane_id"] as? String {
                return (try? tmuxCanonicalPaneId(
                    currentPaneId,
                    workspaceId: canonicalWorkspaceId,
                    client: client
                )) ?? currentPaneId
            }
            if let currentPaneRef = currentPayload["pane_ref"] as? String {
                return (try? tmuxCanonicalPaneId(currentPaneRef, workspaceId: canonicalWorkspaceId, client: client)) ?? currentPaneRef
            }
            return nil
        }()
        let resolvedSurfaceId: String? = try {
            if let surfaceId {
                return (try? tmuxCanonicalSurfaceId(surfaceId, workspaceId: canonicalWorkspaceId, client: client)) ?? surfaceId
            }
            if let resolvedPaneId {
                return try tmuxSelectedSurfaceId(
                    workspaceId: canonicalWorkspaceId,
                    paneId: resolvedPaneId,
                    client: client
                )
            }
            return currentPayload["surface_id"] as? String
        }()

        if let resolvedPaneId {
            context["pane_id"] = "%\(tmuxStableNumericId(resolvedPaneId))"
            context["pane_uuid"] = resolvedPaneId
            let panePayload = try client.sendV2(method: "pane.list", params: ["workspace_id": canonicalWorkspaceId])
            let panes = panePayload["panes"] as? [[String: Any]] ?? []
            if let pane = panes.first(where: { ($0["id"] as? String) == resolvedPaneId }) {
                if let index = intFromAny(pane["index"]) {
                    context["pane_index"] = String(index)
                }
                if let focused = boolFromAny(pane["focused"]) {
                    context["pane_active"] = focused ? "1" : "0"
                }
            }
        }

        if let resolvedSurfaceId {
            context["surface_id"] = resolvedSurfaceId
            let surfacePayload = try client.sendV2(method: "surface.list", params: ["workspace_id": canonicalWorkspaceId])
            let surfaces = surfacePayload["surfaces"] as? [[String: Any]] ?? []
            if let surface = surfaces.first(where: { ($0["id"] as? String) == resolvedSurfaceId }) {
                let title = ((surface["title"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !title.isEmpty {
                    context["pane_title"] = title
                    context["window_name"] = context["window_name"] ?? title
                }
                if let path = tmuxPathFromObject(surface) {
                    context["pane_current_path"] = path
                }
                let paneStartCommand = [
                    surface["tmux_start_command"],
                    surface["pane_start_command"],
                    surface["initial_command"]
                ]
                    .compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .first { !$0.isEmpty }
                if let paneStartCommand {
                    context["pane_start_command"] = paneStartCommand
                    if let currentCommand = tmuxCurrentCommandName(from: paneStartCommand) {
                        context["pane_current_command"] = currentCommand
                    }
                }
            }
        }

        return context
    }

    private func tmuxCompatResolvedSocketPath(processEnvironment: [String: String]) throws -> String {
        let envSocketPath = try CLISocketEnvironment.socketPath(in: processEnvironment)
        let bundleIdentifier = CLISocketPathResolver.currentAppBundleIdentifier()

        let requestedSocketPath = envSocketPath ?? CLISocketPathResolver.defaultSocketPath(
            bundleIdentifier: bundleIdentifier,
            environment: processEnvironment
        )
        let source: CLISocketPathSource
        if let envSocketPath {
            source = CLISocketPathResolver.isImplicitDefaultPath(
                envSocketPath,
                bundleIdentifier: bundleIdentifier,
                environment: processEnvironment
            ) ? .implicitDefault : .environment
        } else {
            source = .implicitDefault
        }

        return CLISocketPathResolver.resolve(
            requestedPath: requestedSocketPath,
            source: source,
            environment: processEnvironment,
            bundleIdentifier: bundleIdentifier
        )
    }

    func tmuxCompatFocusedContext(
        processEnvironment: [String: String],
        explicitPassword: String?
    ) throws -> TmuxCompatFocusedContext? {
        let socketPath = try tmuxCompatResolvedSocketPath(processEnvironment: processEnvironment)
        let client = SocketClient(path: socketPath)

        do {
            try client.connect()
            try authenticateClientIfNeeded(
                client,
                explicitPassword: explicitPassword,
                socketPath: socketPath
            )
            defer { client.close() }

            let payload = try client.sendV2(method: "system.identify")
            let focused = payload["focused"] as? [String: Any] ?? [:]

            let workspaceId = (focused["workspace_id"] as? String)
                ?? (focused["workspace_ref"] as? String)
            let paneId = (focused["pane_id"] as? String)
                ?? (focused["pane_ref"] as? String)

            guard let workspaceId, let paneId else {
                return nil
            }

            let paneHandle = paneId.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !paneHandle.isEmpty else {
                return nil
            }

            let canonicalPaneId: String? = {
                guard let canonicalWorkspaceId = try? resolveWorkspaceId(workspaceId, client: client) else {
                    return nil
                }
                if let paneUUID = normalizedTmuxTarget(focused["pane_uuid"] as? String) {
                    return paneUUID
                }
                if let paneId = normalizedTmuxTarget(focused["pane_id"] as? String),
                   let canonical = try? tmuxCanonicalPaneId(
                       paneId,
                       workspaceId: canonicalWorkspaceId,
                       client: client
                   ) {
                    return canonical
                }
                return try? tmuxCanonicalPaneId(
                    paneHandle,
                    workspaceId: canonicalWorkspaceId,
                    client: client
                )
            }()

            let windowId = (focused["window_id"] as? String)
                ?? (focused["window_ref"] as? String)
            let surfaceId = (focused["surface_id"] as? String)
                ?? (focused["surface_ref"] as? String)

            return TmuxCompatFocusedContext(
                socketPath: socketPath,
                workspaceId: workspaceId,
                windowId: windowId,
                paneHandle: paneHandle,
                paneId: canonicalPaneId,
                surfaceId: surfaceId
            )
        } catch {
            client.close()
            return nil
        }
    }

}

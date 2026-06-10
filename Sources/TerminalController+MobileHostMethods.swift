import AppKit
import CmuxAuthRuntime
import CmuxControlSocket
import CmuxSettings
import CmuxSocketControl
import CmuxSwiftRenderUI
import Carbon.HIToolbox
import CMUXMobileCore
import CMUXWorkstream
import Foundation
import Bonsplit
import WebKit


// MARK: - Mobile host RPC, tickets, and workspace methods
extension TerminalController {
    @MainActor
    func mobileHostHandleRPC(_ request: MobileHostRPCRequest) async -> MobileHostRPCResult {
        let result: V2CallResult
        switch request.method {
        case "mobile.host.status":
            result = v2MobileHostStatus(params: request.params, includePrivateMetadata: false)
        case "mobile.attach_ticket.create":
            result = await v2MobileAttachTicketCreate(params: request.params)
        case "mobile.workspace.list", "workspace.list":
            result = v2MobileWorkspaceList(params: request.params)
        case "workspace.create":
            result = v2MobileWorkspaceCreate(params: request.params)
        case "mobile.terminal.create", "terminal.create":
            result = v2MobileTerminalCreate(params: request.params)
        case "mobile.terminal.input", "terminal.input":
            result = v2MobileTerminalInput(params: request.params)
        case "mobile.terminal.paste_image", "terminal.paste_image":
            result = v2MobileTerminalPasteImage(params: request.params)
        case "mobile.terminal.replay", "terminal.replay":
            result = v2MobileTerminalReplay(params: request.params)
        case "mobile.terminal.viewport", "terminal.viewport":
            result = v2MobileTerminalViewport(params: request.params)
        case "mobile.terminal.scroll", "terminal.scroll":
            result = v2MobileTerminalScroll(params: request.params)
        case "mobile.terminal.mouse", "terminal.mouse":
            result = v2MobileTerminalMouse(params: request.params)
        case "workspace.action":
            result = v2MobileWorkspaceAction(params: request.params)
#if DEBUG
        case "dogfood.feedback.submit":
            result = await v2MobileDogfoodFeedbackSubmit(params: request.params)
#endif
        default:
            result = .err(code: "method_not_found", message: "Unknown mobile method", data: [
                "method": request.method
            ])
        }
        return mobileHostResult(result)
    }

#if DEBUG
    /// Hard caps for the DEV dogfood feedback sink. A debug client is the only
    /// caller, but a malformed or hostile request must not be able to allocate
    /// huge buffers, block the Mac UI, or grow the cache without bound. Strings
    /// are capped by character count before any large allocation; the base64
    /// blob is rejected outright past its cap (so it is never decoded), and a
    /// decoded blob past the byte cap is dropped.
    nonisolated private static let dogfoodFeedbackMaxTextChars = 16_384
    nonisolated private static let dogfoodFeedbackMaxTerminalChars = 262_144
    nonisolated private static let dogfoodFeedbackMaxBuildStampChars = 512
    nonisolated private static let dogfoodFeedbackMaxBlobBase64Chars = 8_388_608 // ~6 MiB decoded
    nonisolated private static let dogfoodFeedbackMaxBlobBytes = 6_291_456 // 6 MiB
    /// Keep at most this many bundle directories; older ones are pruned after
    /// each write so a retrying client can't grow the cache without bound.
    nonisolated private static let dogfoodFeedbackMaxRetainedBundles = 50

    /// DEV-only dogfood feedback sink (P1 of the Mac↔phone feedback loop).
    ///
    /// Decodes `{ text, terminal_text, build_stamp, diagnostic_blob_base64 }`,
    /// writes a self-contained bundle directory under
    /// `~/.cache/cmux-dogfood-feedback/<ISO8601>_<shortid>/` (a `bundle.json`
    /// manifest plus the decoded `diagnostic.log`), and returns the bundle path.
    /// Gated behind `#if DEBUG` and the same-account Stack-auth authorization the
    /// rest of the mobile data plane enforces, so it never exists in a release
    /// build and never accepts an unauthenticated caller.
    ///
    /// Field sizes are capped on the main actor *before* any large allocation,
    /// invalid/oversized base64 is rejected without decoding, and the decode +
    /// filesystem writes run off the main actor so a large payload cannot block
    /// the Mac UI.
    private func v2MobileDogfoodFeedbackSubmit(params: [String: Any]) async -> V2CallResult {
        // Cheap main-actor validation first: cap each field by character count
        // before allocating anything large, and reject an oversized base64 blob
        // outright so it is never decoded into a giant Data.
        let text = String((v2RawString(params, "text") ?? "").prefix(Self.dogfoodFeedbackMaxTextChars))
        let terminalText = String((v2RawString(params, "terminal_text") ?? "").prefix(Self.dogfoodFeedbackMaxTerminalChars))
        let buildStamp = String((v2RawString(params, "build_stamp") ?? "").prefix(Self.dogfoodFeedbackMaxBuildStampChars))
        let diagnosticBlobBase64 = v2RawString(params, "diagnostic_blob_base64") ?? ""
        guard diagnosticBlobBase64.count <= Self.dogfoodFeedbackMaxBlobBase64Chars else {
            return .err(
                code: "invalid_params",
                message: "diagnostic_blob_base64 exceeds size limit",
                data: nil
            )
        }

        let maxBlobBytes = Self.dogfoodFeedbackMaxBlobBytes
        // Off-main: decode the blob and write the bundle. A `Task.detached`
        // keeps the (potentially multi-MiB) decode + synchronous file I/O off the
        // main actor so it never stalls the Mac UI. Returns a Sendable result.
        let outcome = await Task.detached(priority: .utility) { () -> DogfoodFeedbackWriteOutcome in
            let decoded = Data(base64Encoded: diagnosticBlobBase64) ?? Data()
            guard decoded.count <= maxBlobBytes else {
                return .rejected(reason: "diagnostic blob exceeds size limit")
            }
            return Self.writeDogfoodFeedbackBundle(
                text: text,
                terminalText: terminalText,
                buildStamp: buildStamp,
                diagnosticData: decoded
            )
        }.value

        switch outcome {
        case let .written(bundlePath, byteCount):
            return .ok([
                "ok": true,
                "bundle_path": bundlePath,
                "diagnostic_log_bytes": byteCount,
            ])
        case let .rejected(reason):
            return .err(code: "invalid_params", message: reason, data: nil)
        case .failed:
            return .err(
                code: "internal_error",
                message: "Failed to persist dogfood feedback bundle",
                data: nil
            )
        }
    }

    /// The result of writing a dogfood feedback bundle off the main actor.
    private enum DogfoodFeedbackWriteOutcome: Sendable {
        case written(bundlePath: String, byteCount: Int)
        case rejected(reason: String)
        case failed
    }

    /// Persist a validated dogfood feedback bundle to disk. Runs off the main
    /// actor (called from a detached task), so its synchronous file I/O never
    /// blocks the Mac UI. All inputs are already size-capped by the caller.
    nonisolated private static func writeDogfoodFeedbackBundle(
        text: String,
        terminalText: String,
        buildStamp: String,
        diagnosticData: Data
    ) -> DogfoodFeedbackWriteOutcome {
        let fileManager = FileManager.default
        let root = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache", isDirectory: true)
            .appendingPathComponent("cmux-dogfood-feedback", isDirectory: true)

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        // Colons are legal in HFS+/APFS but awkward in shell globs; swap for `-`
        // so the directory name is paste-safe.
        let timestamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let shortID = String(UUID().uuidString.prefix(8)).lowercased()
        let bundleDir = root.appendingPathComponent("\(timestamp)_\(shortID)", isDirectory: true)

        do {
            // The bundle holds visible terminal text and debug logs, which can
            // contain credentials or other private data. Create the root and
            // bundle dirs owner-only (0700) so no other local user can traverse
            // into them, and chmod the written files to 0600. The dir is created
            // 0700 first, so even the brief window before the file chmod is not
            // world-readable through a traversable parent.
            let dirAttributes: [FileAttributeKey: Any] = [.posixPermissions: 0o700]
            try fileManager.createDirectory(
                at: root,
                withIntermediateDirectories: true,
                attributes: dirAttributes
            )
            try fileManager.createDirectory(
                at: bundleDir,
                withIntermediateDirectories: true,
                attributes: dirAttributes
            )
            let diagnosticURL = bundleDir.appendingPathComponent("diagnostic.log")
            try diagnosticData.write(to: diagnosticURL)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: diagnosticURL.path)
            let manifest: [String: Any] = [
                "schema": "cmux.dogfood.feedback.v1",
                "received_at": formatter.string(from: Date()),
                "text": text,
                "terminal_text": terminalText,
                "build_stamp": buildStamp,
                "diagnostic_log_file": "diagnostic.log",
                "diagnostic_log_bytes": diagnosticData.count,
            ]
            let manifestData = try JSONSerialization.data(
                withJSONObject: manifest,
                options: [.prettyPrinted, .sortedKeys]
            )
            let manifestURL = bundleDir.appendingPathComponent("bundle.json")
            try manifestData.write(to: manifestURL)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifestURL.path)
        } catch {
            return .failed
        }

        pruneDogfoodFeedbackBundles(root: root, keep: dogfoodFeedbackMaxRetainedBundles)
        return .written(bundlePath: bundleDir.path, byteCount: diagnosticData.count)
    }

    /// Keep only the newest `keep` bundle directories under `root`, deleting the
    /// rest. The directory names start with an ISO8601 timestamp, so a
    /// lexicographic sort is chronological. Best-effort: a failure to enumerate
    /// or remove is ignored (it only affects cleanup, not the just-written
    /// bundle). Runs off the main actor with its writer.
    nonisolated private static func pruneDogfoodFeedbackBundles(root: URL, keep: Int) {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        let directories = entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard directories.count > keep else { return }
        for stale in directories.dropLast(keep) {
            try? fileManager.removeItem(at: stale)
        }
    }
#endif

    /// The `workspace.action` sub-actions the mobile data plane may invoke.
    ///
    /// Mobile gets pin/unpin/rename only. The other sub-actions of
    /// ``v2WorkspaceAction(params:)`` (`move_*`, `close_*`, `set_color`,
    /// `set_description`, `mark_*`, …) reorder the global sidebar or destroy
    /// sibling workspaces, so they stay on the Mac/automation socket. The action
    /// is normalized exactly as ``v2ActionKey(_:_:)`` so this gate and the
    /// handler can never disagree on which action runs.
    /// - Parameter rawAction: The raw `action` param value.
    /// - Returns: `true` when the normalized action is mobile-allowed.
    nonisolated static func mobileAllowsWorkspaceAction(_ rawAction: String?) -> Bool {
        guard let trimmed = rawAction?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return false }
        let normalized = trimmed.lowercased().replacingOccurrences(of: "-", with: "_")
        return ["pin", "unpin", "rename"].contains(normalized)
    }

    /// Mobile-gated wrapper over ``v2WorkspaceAction(params:)``: rejects every
    /// sub-action except pin/unpin/rename before dispatching.
    private func v2MobileWorkspaceAction(params: [String: Any]) -> V2CallResult {
        let rawAction = v2RawString(params, "action")
        guard Self.mobileAllowsWorkspaceAction(rawAction) else {
            return .err(
                code: "method_not_found",
                message: "Unsupported workspace action for mobile",
                data: ["action": v2OrNull(rawAction)]
            )
        }
        // Reject a present-but-malformed workspace_id like the other mobile
        // handlers, then require it to actually be present and resolvable: this
        // is a mutating action, so it must target an explicit workspace and never
        // fall back to the Mac's currently selected workspace (which
        // v2WorkspaceAction would otherwise do for a missing workspace_id).
        if let error = mobileWorkspaceIDValidationError(params: params) {
            return error
        }
        guard v2UUID(params, "workspace_id") != nil else {
            return .err(code: "invalid_params", message: "Missing or invalid workspace_id", data: nil)
        }
        return v2WorkspaceAction(params: params)
    }

    private func mobileHostResult(_ result: V2CallResult) -> MobileHostRPCResult {
        switch result {
        case let .ok(payload):
            return .ok(payload)
        case let .err(code, message, data):
            let safeMessage = code == "internal_error" ? "Mobile host operation failed" : message
            let safeData = code == "internal_error" ? nil : data
            return .failure(MobileHostRPCError(code: code, message: safeMessage, data: safeData))
        }
    }

    func v2MobileHostStatus(
        params: [String: Any],
        includePrivateMetadata: Bool = true
    ) -> V2CallResult {
        let status = MobileHostService.shared.statusSnapshot()
        // Single source of truth shared with the mobile listener's public-status
        // paths, so the advertised capabilities can never drift. Includes
        // workspace.actions.v1 (the mobile-gated pin/unpin/rename handler), which
        // the iOS client uses to show or hide rename/pin.
        let capabilities = MobileHostService.mobileHostCapabilities
        guard includePrivateMetadata else {
            return .ok([
                "routes": status.routes.map(\.mobileHostJSONObject),
                "terminal_fidelity": "render_grid",
                "capabilities": capabilities,
            ])
        }

        let tabManager = v2ResolveTabManager(params: params)
        let workspaceCount = tabManager?.tabs.count ?? 0

        return .ok([
            "mac_device_id": MobileHostIdentity.deviceID(),
            "mac_display_name": v2OrNull(MobileHostIdentity.displayName()),
            "host_service": status.payload,
            "workspace_count": workspaceCount,
            "terminal_fidelity": "render_grid",
            "capabilities": capabilities,
        ])
    }

    #if DEBUG
    func v2MobileDevStackAuthConfigure(params: [String: Any]) -> V2CallResult {
        let enabled = v2Bool(params, "enabled")
        let token = v2OptionalTrimmedRawString(params, "token")
        if enabled == false {
            MobileHostService.shared.debugConfigureAcceptedStackAuthTokenForTesting(nil)
            return .ok(["enabled": false])
        }

        guard let token else {
            return .err(
                code: "invalid_params",
                message: "mobile.dev_stack_auth.configure requires params.token",
                data: nil
            )
        }

        MobileHostService.shared.debugConfigureAcceptedStackAuthTokenForTesting(token)
        return .ok([
            "enabled": true,
            "token_prefix": String(token.prefix(8))
        ])
    }
    #endif

    @MainActor
    func v2MobileAttachTicketCreate(params: [String: Any]) async -> V2CallResult {
        let ttl = TimeInterval(max(30, min(v2Int(params, "ttl_seconds") ?? 600, 3600)))
        let routeID = v2OptionalTrimmedRawString(params, "route_id")
            ?? v2OptionalTrimmedRawString(params, "routeID")
        let routeKind = v2OptionalTrimmedRawString(params, "route_kind")
            ?? v2OptionalTrimmedRawString(params, "routeKind")
        let scope = v2OptionalTrimmedRawString(params, "scope")
        // scope=mac mints a Mac-wide ticket that grants access to every
        // workspace on the host. Without this, the ticket gets pinned to
        // the workspace selected at QR-generation time, and tapping any
        // other workspace from the paired iPhone falls back to Stack
        // Auth verification, which is brittle on real-world networks.
        let isMacScope = scope?.lowercased() == "mac"

        if let error = mobileWorkspaceIDValidationError(params: params) {
            return error
        }
        if let error = mobileTerminalAliasValidationError(params: params) {
            return error
        }

        let resolvedWorkspaceID: String
        let resolvedTerminalID: String?
        if isMacScope {
            resolvedWorkspaceID = ""
            resolvedTerminalID = nil
        } else {
            guard let resolved = mobileResolveWorkspaceAndSurface(params: params, requireTerminal: false) else {
                return .err(code: "not_found", message: "Workspace not found", data: nil)
            }
            let terminalPanel: TerminalPanel?
            if let surfaceId = resolved.surfaceId {
                guard let panel = resolved.workspace.terminalPanel(for: surfaceId) else {
                    return .err(
                        code: "invalid_request",
                        message: "terminal_id does not reference a terminal",
                        data: nil
                    )
                }
                terminalPanel = panel
            } else {
                terminalPanel = nil
            }
            resolvedWorkspaceID = resolved.workspace.id.uuidString
            resolvedTerminalID = terminalPanel?.id.uuidString
        }

        do {
            let payload = try await MobileHostService.shared.createAttachTicket(
                workspaceID: resolvedWorkspaceID,
                terminalID: resolvedTerminalID,
                ttl: ttl,
                routeID: routeID,
                routeKind: routeKind
            )
            return .ok(payload)
        } catch MobileAttachTicketStoreError.noRoutes {
            return .err(
                code: "unavailable",
                message: "Mobile host routes are not available yet",
                data: nil
            )
        } catch MobileAttachTicketStoreError.routeUnavailable {
            var data: [String: Any] = [:]
            if let routeID {
                data["route_id"] = routeID
            }
            if let routeKind {
                data["route_kind"] = routeKind
            }
            return .err(
                code: "unavailable",
                message: "Requested mobile host route is not available",
                data: data.isEmpty ? nil : data
            )
        } catch {
            return .err(
                code: "internal_error",
                message: "Failed to create mobile attach ticket",
                data: ["error": String(describing: error)]
            )
        }
    }

    func v2MobileWorkspaceList(
        params: [String: Any],
        tabManager resolvedTabManager: TabManager? = nil,
        createdWorkspaceID: String? = nil,
        createdTerminalID: String? = nil
    ) -> V2CallResult {
        let requestedWorkspaceID = v2UUID(params, "workspace_id")
        if v2HasNonNullParam(params, "workspace_id"), requestedWorkspaceID == nil {
            return .err(code: "invalid_params", message: "Missing or invalid workspace_id", data: nil)
        }
        let requestedTerminalID: UUID?
        switch mobileTerminalAliasUUID(params: params) {
        case .missing:
            requestedTerminalID = nil
        case let .value(terminalID):
            requestedTerminalID = terminalID
        case .invalid:
            return .err(code: "invalid_params", message: "Missing or invalid terminal_id", data: nil)
        case .conflict:
            return .err(code: "invalid_params", message: "Conflicting terminal identifiers", data: nil)
        }

        // The phone shows workspaces from *every* open Mac window. Enumerate all
        // registered main windows and flatten their workspaces into one list,
        // but only when the caller has not named a specific target. When a
        // `workspace_id`, `window_id`, terminal alias, or an explicit
        // `resolvedTabManager` (the create/terminal-create paths pass one) is
        // present, keep today's single-window scoped behavior so those requests
        // resolve exactly the named target.
        let scopeToSingleWindow = resolvedTabManager != nil
            || requestedWorkspaceID != nil
            || v2HasNonNullParam(params, "window_id")
            || requestedTerminalID != nil

        // `is_selected` has no single answer across multiple windows. Mark only
        // the frontmost/key window's selected workspace as selected; in the old
        // single-window path this is exactly the one selected workspace. Using
        // `currentScriptableMainWindow()` (not `isKeyWindow`) means a backgrounded
        // app, where no window is key, still reports the same selection the old
        // path would have, instead of marking nothing selected.
        let selectedWorkspaceID = scopeToSingleWindow
            ? nil
            : AppDelegate.shared?.currentScriptableMainWindow()?.tabManager.selectedTabId

        let workspaces: [[String: Any]]
        if scopeToSingleWindow {
            guard let tabManager = resolvedTabManager ?? v2ResolveTabManager(params: params) else {
                return .err(code: "unavailable", message: "Workspace context is unavailable", data: nil)
            }
            let visibleWorkspaces = requestedWorkspaceID.map { workspaceID in
                tabManager.tabs.filter { $0.id == workspaceID }
            } ?? tabManager.tabs
            if let requestedWorkspaceID, visibleWorkspaces.isEmpty {
                return .err(
                    code: "not_found",
                    message: "Workspace not found",
                    data: ["workspace_id": requestedWorkspaceID.uuidString]
                )
            }
            let scopedWorkspaces = visibleWorkspaces.map { workspace in
                mobileWorkspacePayload(
                    workspace: workspace,
                    isSelected: workspace.id == tabManager.selectedTabId,
                    requestedTerminalID: requestedTerminalID
                )
            }
            if let requestedTerminalID,
               !scopedWorkspaces.contains(where: { workspace in
                   guard let terminals = workspace["terminals"] as? [[String: Any]] else { return false }
                   return terminals.contains { ($0["id"] as? String) == requestedTerminalID.uuidString }
               }) {
                return .err(
                    code: "not_found",
                    message: "Terminal not found",
                    data: ["surface_id": requestedTerminalID.uuidString]
                )
            }
            workspaces = scopedWorkspaces
        } else {
            guard let app = AppDelegate.shared else {
                return .err(code: "unavailable", message: "Workspace context is unavailable", data: nil)
            }
            var flattened: [[String: Any]] = []
            // `listMainWindowSummaries()` already dedupes window ids, but guard
            // against the same window or workspace appearing twice anyway: a
            // workspace lives in exactly one window, and ids are globally unique.
            var seenWindowIDs: Set<UUID> = []
            var seenWorkspaceIDs: Set<UUID> = []
            for summary in app.listMainWindowSummaries() {
                guard seenWindowIDs.insert(summary.windowId).inserted else { continue }
                guard let windowTabManager = app.tabManagerFor(windowId: summary.windowId) else { continue }
                for workspace in windowTabManager.tabs where seenWorkspaceIDs.insert(workspace.id).inserted {
                    flattened.append(
                        mobileWorkspacePayload(
                            workspace: workspace,
                            isSelected: workspace.id == selectedWorkspaceID,
                            requestedTerminalID: requestedTerminalID
                        )
                    )
                }
            }
            workspaces = flattened
        }

        var payload: [String: Any] = [
            "workspaces": workspaces
        ]
        if let createdWorkspaceID {
            payload["created_workspace_id"] = createdWorkspaceID
        }
        if let createdTerminalID {
            payload["created_terminal_id"] = createdTerminalID
        }
        return .ok(payload)
    }

    /// Serializes one workspace into the iOS-facing mobile workspace list shape.
    ///
    /// Shared by the single-window (scoped) and all-windows enumeration branches
    /// of `v2MobileWorkspaceList` so the two never diverge. When
    /// `requestedTerminalID` is non-nil the terminals array is filtered to that
    /// one terminal (only the scoped branch passes it; the all-windows branch
    /// always passes nil, so it lists every terminal). The scoped
    /// terminal-not-found check is enforced by the caller after the list is built.
    private func mobileWorkspacePayload(
        workspace: Workspace,
        isSelected: Bool,
        requestedTerminalID: UUID?
    ) -> [String: Any] {
        let terminals = mobileTerminalPanels(in: workspace).compactMap { terminal -> [String: Any]? in
            if let requestedTerminalID, terminal.id != requestedTerminalID {
                return nil
            }
            return [
                "id": terminal.id.uuidString,
                "title": workspace.panelTitle(panelId: terminal.id) ?? terminal.displayTitle,
                "current_directory": v2OrNull(
                    mobileNonEmpty(workspace.panelDirectories[terminal.id])
                        ?? mobileNonEmpty(terminal.directory)
                        ?? mobileNonEmpty(terminal.requestedWorkingDirectory)
                ),
                "is_ready": terminal.surface.surface != nil,
                "is_focused": terminal.id == workspace.focusedPanelId
            ]
        }

        return [
            "id": workspace.id.uuidString,
            "title": workspace.title,
            "current_directory": v2OrNull(mobileNonEmpty(workspace.currentDirectory)),
            "is_selected": isSelected,
            "is_pinned": workspace.isPinned,
            "terminals": terminals
        ]
    }

}

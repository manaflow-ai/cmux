import AppKit
import CmuxWorkspaces
import Foundation

// MARK: - Mobile workspace list (iOS-facing payloads)
//
// The phone's `workspace.list` surface: enumerating workspaces across windows,
// serializing the workspace and group-section payloads, and the mobile-gated
// group collapse/expand handler. Lives in its own file so the mobile list
// payload code stays together without growing TerminalController.swift.
extension TerminalController {
    /// Mobile-gated collapse/expand of a workspace group. P1 group support on
    /// iOS is display-only: the phone renders collapsible group sections and can
    /// toggle a section open/closed, but cannot create, rename, or restructure
    /// groups. This requires an explicit, resolvable `group_id` (it must never
    /// fall back to the Mac's selected group) and mutates through the same
    /// `TabManager.setWorkspaceGroupCollapsed` the CLI and sidebar use, so the
    /// mutation path stays shared. `v2ResolveTabManager` routes by `group_id` to
    /// the owning window even in the multi-window case.
    func v2MobileWorkspaceGroupSetCollapsed(params: [String: Any], isCollapsed: Bool) -> V2CallResult {
        guard v2HasNonNullParam(params, "group_id"), let gid = v2UUID(params, "group_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid group_id", data: nil)
        }
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        var ok = false
        v2MainSync {
            ok = tabManager.workspaceGroups.contains(where: { $0.id == gid })
            if ok { tabManager.setWorkspaceGroupCollapsed(groupId: gid, isCollapsed: isCollapsed) }
        }
        return ok
            ? .ok(["group_id": gid.uuidString, "is_collapsed": isCollapsed])
            : .err(code: "not_found", message: "Group not found", data: ["group_id": gid.uuidString])
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
        // Group sections shown on the phone. Aggregated alongside the workspace
        // list so the iOS client can fold contiguous same-group workspaces under a
        // collapsible header that mirrors the Mac sidebar.
        var groups: [[String: Any]] = []
        if scopeToSingleWindow {
            guard let tabManager = resolvedTabManager ?? v2ResolveTabManager(params: params) else {
                return .err(code: "unavailable", message: "Workspace context is unavailable", data: nil)
            }
            // Only include groups when listing the whole window. A request scoped
            // to one workspace or terminal is a targeted lookup (create/refresh of
            // a single entry), not a sidebar render, so it omits group sections to
            // keep the response minimal. The phone always lists the full window.
            if requestedWorkspaceID == nil, requestedTerminalID == nil {
                groups = mobileWorkspaceGroupPayloads(tabManager.workspaceGroups, tabs: tabManager.tabs)
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
                    windowID: v2ResolveWindowId(tabManager: tabManager),
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
            // Groups are per-TabManager (per window). Aggregate them in the same
            // window-iteration order the workspaces are flattened in, so a group's
            // header lands at its first member's position in the combined list.
            var aggregatedGroups: [[String: Any]] = []
            for summary in app.listMainWindowSummaries() {
                guard seenWindowIDs.insert(summary.windowId).inserted else { continue }
                guard let windowTabManager = app.tabManagerFor(windowId: summary.windowId) else { continue }
                aggregatedGroups.append(
                    contentsOf: mobileWorkspaceGroupPayloads(
                        windowTabManager.workspaceGroups,
                        tabs: windowTabManager.tabs
                    )
                )
                for workspace in windowTabManager.tabs where seenWorkspaceIDs.insert(workspace.id).inserted {
                    flattened.append(
                        mobileWorkspacePayload(
                            workspace: workspace,
                            windowID: summary.windowId,
                            isSelected: workspace.id == selectedWorkspaceID,
                            requestedTerminalID: requestedTerminalID
                        )
                    )
                }
            }
            workspaces = flattened
            groups = aggregatedGroups
        }

        var payload: [String: Any] = [
            "workspaces": workspaces,
            "groups": groups
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
    /// `notificationStore` defaults to the app-global store; tests inject one so
    /// the unread/activity fields are deterministic.
    func mobileWorkspacePayload(
        workspace: Workspace,
        windowID: UUID? = nil,
        isSelected: Bool,
        requestedTerminalID: UUID?,
        notificationStore: TerminalNotificationStore? = nil
    ) -> [String: Any] {
        let terminals = mobileTerminalPanels(in: workspace).compactMap { terminal -> [String: Any]? in
            if let requestedTerminalID, terminal.id != requestedTerminalID {
                return nil
            }
            let terminalDirectory = workspace.reportedPanelDirectory(panelId: terminal.id)
                ?? (workspace.isRemoteTerminalSurface(terminal.id)
                    ? nil
                    : mobileNonEmpty(terminal.directory) ?? mobileNonEmpty(terminal.requestedWorkingDirectory))
            return [
                "id": terminal.id.uuidString,
                "title": workspace.panelTitle(panelId: terminal.id) ?? terminal.displayTitle,
                "current_directory": v2OrNull(terminalDirectory),
                "is_ready": terminal.surface.surface != nil,
                "is_focused": terminal.id == workspace.focusedPanelId
            ]
        }

        let store = notificationStore ?? AppDelegate.shared?.notificationStore
        let latestNotification = store?.latestNotification(forTabId: workspace.id)
        let preview = Self.mobileWorkspacePreview(latestNotification: latestNotification)
        return [
            "id": workspace.id.uuidString,
            "window_id": v2OrNull(windowID?.uuidString),
            "title": workspace.title,
            "current_directory": v2OrNull(workspace.presentedCurrentDirectory),
            "is_selected": isSelected,
            "is_pinned": workspace.isPinned,
            // Group membership so the phone can fold contiguous same-group
            // workspaces under their group header. nil for ungrouped workspaces.
            "group_id": v2OrNull(workspace.groupId?.uuidString),
            // iMessage-style last-activity preview: a one-line, plain-text summary
            // of the most recent notification (agent/terminal activity), with its
            // timestamp, so the phone can show a preview + relative time per row.
            // nil when the workspace has no activity yet.
            "preview": v2OrNull(preview?.text),
            "preview_at": v2OrNull(preview?.epochSeconds),
            // Every row carries a last-activity stamp so the phone can always
            // render a relative time: the latest notification when there is one,
            // the workspace's creation/restore time otherwise. preview_at alone
            // left quiet workspaces with no timestamp at all.
            "last_activity_at": (latestNotification?.createdAt ?? workspace.createdAt).timeIntervalSince1970,
            // Mirrors the Mac sidebar's workspace unread badge (notification
            // unread + manual/panel-derived/restored indicators) so the phone can
            // show an iMessage-style unread dot.
            "has_unread": store?.workspaceIsUnread(forTabId: workspace.id) ?? false,
            "terminals": terminals
        ]
    }

    /// Mobile-gated close of one explicit workspace. The Mac remains
    /// authoritative: protected/last-workspace cases are rejected here and the
    /// phone refreshes afterward to snap back to the real list state.
    func v2MobileWorkspaceClose(params: [String: Any]) -> V2CallResult {
        if v2HasNonNullParam(params, "workspace_id"), v2UUID(params, "workspace_id") == nil {
            return .err(code: "invalid_params", message: "Missing or invalid workspace_id", data: nil)
        }
        guard let workspaceID = v2UUID(params, "workspace_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid workspace_id", data: nil)
        }
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "Workspace context is unavailable", data: nil)
        }

        var result: V2CallResult = .err(code: "internal_error", message: "Failed to close workspace", data: nil)
        v2MainSync {
            let windowID = v2ResolveWindowId(tabManager: tabManager)
            guard let workspace = tabManager.tabs.first(where: { $0.id == workspaceID }) else {
                result = .err(code: "not_found", message: "Workspace not found", data: [
                    "workspace_id": workspaceID.uuidString
                ])
                return
            }
            guard tabManager.tabs.count > 1, tabManager.canCloseWorkspace(workspace) else {
                result = .err(
                    code: "protected",
                    message: String(
                        localized: "workspace.closeBlocked.message",
                        defaultValue: "This workspace can't be closed right now."
                    ),
                    data: [
                        "workspace_id": workspaceID.uuidString,
                        "workspace_ref": v2Ref(kind: .workspace, uuid: workspaceID),
                        "window_id": v2OrNull(windowID?.uuidString),
                        "window_ref": v2Ref(kind: .window, uuid: windowID),
                    ]
                )
                return
            }
            tabManager.closeWorkspace(workspace)
            result = .ok([
                "closed": true,
                "workspace_id": workspaceID.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: workspaceID),
                "window_id": v2OrNull(windowID?.uuidString),
                "window_ref": v2Ref(kind: .window, uuid: windowID),
            ])
        }
        return result
    }

    /// The most recent activity line shown under a workspace row on the phone.
    ///
    /// Sourced from the same `latestNotification(forTabId:)` the Mac sidebar uses
    /// for its subtitle (body, falling back to title), so the phone mirrors the
    /// desktop. The text is flattened to a single line, has control/ANSI bytes
    /// stripped, collapses runs of whitespace, and is length-capped so a noisy
    /// notification can never bloat the list payload or wrap the row. `nil` when
    /// the workspace has no notification yet (the row then shows no preview).
    private static func mobileWorkspacePreview(
        latestNotification: TerminalNotification?
    ) -> (text: String, epochSeconds: Double)? {
        guard let notification = latestNotification else { return nil }
        let raw = notification.body.isEmpty ? notification.title : notification.body
        guard let text = Self.mobilePreviewSanitize(raw) else { return nil }
        return (text, notification.createdAt.timeIntervalSince1970)
    }

    /// Maximum characters in a mobile workspace preview line. Long enough for a
    /// useful summary, short enough that the row never wraps and the payload stays
    /// small for big workspace lists.
    nonisolated static let mobilePreviewMaxLength = 140

    /// How much raw notification text the sanitizer is willing to process,
    /// measured in unicode scalars. Notification bodies come from terminal output
    /// and are not length-capped at ingestion, and sanitizing runs on the main
    /// actor for every workspace on every mobile list refresh, so the work must
    /// be bounded before the regex and scalar passes, not after. The bound is in
    /// scalars rather than `Character`s because a single crafted grapheme cluster
    /// can carry an arbitrarily long run of combining scalars; a
    /// Character-counted cap would still scan and emit the whole cluster. A 16x
    /// multiple of the visible cap is plenty to fill the preview even when
    /// escapes and whitespace inflate the raw text; pathological input that is
    /// escapes-only past this bound just yields a shorter (or no) preview.
    nonisolated static let mobilePreviewInputCap = mobilePreviewMaxLength * 16

    /// Flattens arbitrary notification text into a single plain-text preview line:
    /// strips ANSI escape sequences and other control characters, collapses
    /// whitespace runs (including newlines) to single spaces, trims, and caps the
    /// length with an ellipsis. Returns `nil` for empty/whitespace-only input.
    /// Input beyond ``mobilePreviewInputCap`` is never scanned; a truncated input
    /// always renders a trailing ellipsis so the row signals there was more.
    nonisolated static func mobilePreviewSanitize(_ raw: String) -> String? {
        // Bound the work first, walking the scalar view: each step advances one
        // scalar, so `index(_:offsetBy:limitedBy:)` costs at most the cap, never
        // the full body, and a multi-megabyte notification (or one grapheme
        // cluster hiding millions of combining scalars) costs the same as a
        // small one. Scalar-view indices are valid String slice bounds; cutting
        // mid-cluster at worst leaves a degenerate cluster the later passes
        // treat like any other text.
        let scalarView = raw.unicodeScalars
        let bounded: Substring
        let inputWasTruncated: Bool
        if let cutoff = scalarView.index(
            scalarView.startIndex,
            offsetBy: mobilePreviewInputCap,
            limitedBy: scalarView.endIndex
        ), cutoff < scalarView.endIndex {
            bounded = raw[..<cutoff]
            inputWasTruncated = true
        } else {
            bounded = raw[...]
            inputWasTruncated = false
        }
        // Drop ANSI/OSC escape sequences first so their payload bytes don't leak
        // into the preview as stray characters once the ESC is removed. Each
        // alternation also matches an unterminated sequence at end-of-input (the
        // CSI final byte is optional, OSC accepts `$` as terminator) so a
        // sequence cut by the input cap is stripped instead of leaking payload.
        // CSI parameter bytes are the full ECMA-48 0x30-0x3F range (digits and
        // :;<=>?): 24-bit color SGR uses colon-separated parameters
        // (ESC[38:2::255:0:0m), so a digits-only class would leave the
        // sequence tail visible in the preview.
        let withoutEscapes = bounded.replacingOccurrences(
            of: "\u{001B}\\[[0-9:;<=>?]*[ -/]*[@-~]?|\u{001B}\\][^\u{0007}\u{001B}]*(?:\u{0007}|\u{001B}\\\\|$)|\u{001B}[@-Z\\\\-_]",
            with: "",
            options: .regularExpression
        )
        // Replace any remaining control character (including newlines/tabs) and
        // collapse whitespace runs into single spaces.
        let scalars = withoutEscapes.unicodeScalars.map { scalar -> Character in
            (CharacterSet.controlCharacters.contains(scalar) || CharacterSet.whitespacesAndNewlines.contains(scalar))
                ? " "
                : Character(scalar)
        }
        let collapsed = String(scalars)
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
        let trimmed = collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.count <= mobilePreviewMaxLength, !inputWasTruncated {
            return trimmed
        }
        return String(trimmed.prefix(mobilePreviewMaxLength - 1)) + "\u{2026}"
    }

    /// Serializes the window's workspace groups into the iOS-facing mobile shape.
    ///
    /// A subset of `v2WorkspaceGroupPayload` carrying only what the phone needs to
    /// render collapsible sections (no v2 handle refs, color, or icon). Member ids
    /// are taken in `tabs` spatial order so the phone's grouping matches the Mac.
    /// Membership is resolved with a single pass over `tabs` (not a scan per
    /// group), keeping this synchronous RPC path linear on large workspace sets.
    func mobileWorkspaceGroupPayloads(_ groups: [WorkspaceGroup], tabs: [Workspace]) -> [[String: Any]] {
        guard !groups.isEmpty else { return [] }
        var memberIDsByGroup: [UUID: [String]] = [:]
        for workspace in tabs {
            guard let groupId = workspace.groupId else { continue }
            memberIDsByGroup[groupId, default: []].append(workspace.id.uuidString)
        }
        return groups.map { group in
            [
                "id": group.id.uuidString,
                "name": group.name,
                "is_collapsed": group.isCollapsed,
                "is_pinned": group.isPinned,
                "anchor_workspace_id": group.anchorWorkspaceId.uuidString,
                "member_workspace_ids": memberIDsByGroup[group.id] ?? []
            ]
        }
    }
}

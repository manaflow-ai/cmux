import AppKit
import Bonsplit
import CmuxControlSocket
import CmuxFeedback
import Foundation

/// The system-domain witnesses: the byte-faithful bodies of the former
/// `v2SystemTree` tree walk, `v2WorkspaceAction` / `v2TabAction` mutation
/// switches, `v2ExtensionSidebarSnapshot`, `v2SessionRestorePrevious`,
/// `v2SettingsOpen`, `v2FeedbackOpen`, and the DEBUG-only
/// `v2MobileDevStackAuthConfigure`, minus the per-read `v2MainSync` hops (the
/// coordinator already runs on the main actor inside the socket-command policy
/// scope). `system.identify` and `surface.split_off` stay shared app-side
/// bodies (`v2Identify` feeds `system.top` / `system.memory` and the
/// task-manager snapshot; `v2SurfaceSplitOff` is also driven by the v1
/// `drag_surface_to_split`), so their witnesses bridge.
extension TerminalController: ControlSystemContext {

    // MARK: - identify (bridge to the still-shared v2Identify)

    func controlSystemIdentify(params: [String: JSONValue]) -> JSONValue {
        let foundationParams = params.mapValues(\.foundationObject)
        return JSONValue(foundationObject: v2Identify(params: foundationParams)) ?? .object([:])
    }

    // MARK: - system.tree window walk

    func controlSystemTreeWindows(
        requestedWindowID: UUID?,
        includeAllWindows: Bool,
        focusedWindowID: UUID?,
        workspaceFilter: UUID?
    ) -> ControlSystemTreeResolution {
        var windows: [ControlSystemTreeWindowNode] = []
        var workspaceFound = (workspaceFilter == nil)
        var windowFound = (requestedWindowID == nil)

        if let app = AppDelegate.shared {
            let summaries = app.listMainWindowSummaries()
            let defaultWindowId = requestedWindowID ?? focusedWindowID ?? summaries.first?.windowId

            for (windowIndex, summary) in summaries.enumerated() {
                if let requestedWindowID, summary.windowId != requestedWindowID {
                    continue
                }
                windowFound = true
                guard let manager = app.tabManagerFor(windowId: summary.windowId) else { continue }

                if let workspaceFilter {
                    guard let workspaceIndex = manager.tabs.firstIndex(where: { $0.id == workspaceFilter }) else {
                        continue
                    }
                    let workspace = manager.tabs[workspaceIndex]
                    let workspaceNode = controlSystemTreeWorkspaceNode(
                        workspace: workspace,
                        index: workspaceIndex,
                        selected: workspace.id == manager.selectedTabId
                    )
                    windows = [
                        ControlSystemTreeWindowNode(
                            summary: systemTreeWindowSummary(summary),
                            index: windowIndex,
                            workspaces: [workspaceNode]
                        )
                    ]
                    workspaceFound = true
                    break
                }

                if !includeAllWindows && summary.windowId != defaultWindowId {
                    continue
                }

                let workspaceNodesForWindow = manager.tabs.enumerated().map { workspaceIndex, workspace in
                    controlSystemTreeWorkspaceNode(
                        workspace: workspace,
                        index: workspaceIndex,
                        selected: workspace.id == manager.selectedTabId
                    )
                }

                windows.append(
                    ControlSystemTreeWindowNode(
                        summary: systemTreeWindowSummary(summary),
                        index: windowIndex,
                        workspaces: workspaceNodesForWindow
                    )
                )
            }
        }

        return ControlSystemTreeResolution(
            windowFound: windowFound,
            workspaceFound: workspaceFound,
            windows: windows
        )
    }

    private func systemTreeWindowSummary(_ summary: AppDelegate.MainWindowSummary) -> ControlWindowSummary {
        ControlWindowSummary(
            windowID: summary.windowId,
            isKeyWindow: summary.isKeyWindow,
            isVisible: summary.isVisible,
            workspaceCount: summary.workspaceCount,
            selectedWorkspaceID: summary.selectedWorkspaceId
        )
    }

    /// Projects the authoritative control-plane workspace topology shared by
    /// `system.tree`, `system.top`, and the task-manager snapshot.
    func controlSystemTreeWorkspaceNode(
        workspace: Workspace,
        index: Int,
        selected: Bool
    ) -> ControlSystemTreeWorkspaceNode {
        var surfacesByPane: [UUID: [ControlSystemTreeSurfaceNode]] = [:]
        for (surfaceIndex, surface) in controlSurfaceSummaries(workspace: workspace).enumerated() {
            let panel = workspace.controlSurfaceTarget(for: surface.surfaceID)?.panel
            let browserPanel = panel as? BrowserPanel
            let node = ControlSystemTreeSurfaceNode(
                surfaceID: surface.surfaceID,
                index: surfaceIndex,
                typeRawValue: surface.typeRawValue,
                title: surface.title,
                isFocused: surface.isFocused,
                isSelected: surface.selectedInPane ?? false,
                selectedInPane: surface.selectedInPane,
                paneID: surface.paneID,
                indexInPane: surface.indexInPane,
                tty: workspace.surfaceTTYNames[surface.surfaceID],
                isBrowser: browserPanel != nil,
                url: browserPanel?.currentURL?.absoluteString
            )
            if let paneUUID = surface.paneID {
                surfacesByPane[paneUUID, default: []].append(node)
            }
        }

        for paneUUID in surfacesByPane.keys {
            surfacesByPane[paneUUID]?.sort {
                ($0.indexInPane ?? $0.index) < ($1.indexInPane ?? $1.index)
            }
        }

        let paneSummaries = controlPaneSummaries(
            workspace: workspace,
            snapshot: workspace.bonsplitController.layoutSnapshot()
        )
        let panes: [ControlSystemTreePaneNode] = paneSummaries.enumerated().map { paneIndex, pane in
            ControlSystemTreePaneNode(
                paneID: pane.paneID,
                index: paneIndex,
                isFocused: pane.isFocused,
                surfaceIDs: pane.surfaceIDs,
                selectedSurfaceID: pane.selectedSurfaceID,
                surfaces: surfacesByPane[pane.paneID] ?? []
            )
        }

        return ControlSystemTreeWorkspaceNode(
            workspaceID: workspace.id,
            index: index,
            title: workspace.title,
            description: workspace.customDescription,
            isSelected: selected,
            isPinned: workspace.isPinned,
            panes: panes
        )
    }

    // MARK: - auth.login / session / settings / feedback

    func controlAuthPasswordRequired() -> Bool {
        socketServer.accessMode.requiresPasswordAuth
    }

    func controlSessionRestorePrevious() -> ControlSessionRestoreResolution {
        let restored = AppDelegate.shared?.reopenPreviousSession(shouldActivate: false) ?? false
        guard restored else {
            return .noSnapshot(message: String(
                localized: "terminal.restore.no_snapshot",
                defaultValue: "No previous session snapshot available"
            ))
        }
        return .restored
    }

    func controlSettingsOpen(targetRaw: String?, requestedActivate: Bool) -> ControlSettingsOpenResolution {
        let shouldActivate = v2FocusAllowed(requested: requestedActivate)

        let navigationTarget: SettingsNavigationTarget?
        if let targetRaw {
            guard let target = SettingsNavigationTarget(rawValue: targetRaw) else {
                return .invalidTarget
            }
            navigationTarget = target
        } else {
            navigationTarget = nil
        }

        // Present synchronously (this context is @MainActor) so the reply
        // reflects reality: `opened` if-and-only-if a window materialized.
        // "OK but nothing happened" was the #7775 failure shape.
        let result = SettingsWindowPresenter.show(
            navigationTarget: navigationTarget,
            activateApp: shouldActivate
        )
        switch result {
        case .presented, .orderedWhileAppHidden:
            return .opened(target: navigationTarget?.rawValue ?? "general")
        case .failed(let reason):
            return .failed(message: reason)
        }
    }

    func controlFeedbackOpen(workspaceID: UUID?, windowID: UUID?, requestedActivate: Bool) {
        let shouldActivate = v2FocusAllowed(requested: requestedActivate)
        DispatchQueue.main.async {
            let targetWindow: NSWindow?
            if let windowID, let app = AppDelegate.shared {
                targetWindow = app.mainWindow(for: windowID)
            } else if let workspaceID, let app = AppDelegate.shared {
                targetWindow = app.mainWindowContainingWorkspace(workspaceID)
            } else {
                targetWindow = nil
            }

            if shouldActivate {
                if let targetWindow {
                    _ = AppDelegate.shared?.focusWindowForAppActivation(targetWindow, reason: .feedback)
                } else {
                    // The legacy body also passed .activateIgnoringOtherApps; the
                    // option is deprecated and documented as a no-op on macOS 14+
                    // (this target's minimum), so dropping it is behavior-neutral
                    // and keeps this file deprecation-warning-free.
                    NSRunningApplication.current.activate(options: [.activateAllWindows])
                }
            }

            FeedbackComposerBridge().openComposer(in: targetWindow)
        }
    }

    // MARK: - extension.sidebar.snapshot

    func controlExtensionSidebarSnapshot(routing: ControlRoutingSelectors) -> ControlExtensionSidebarSnapshot? {
        guard let tabManager = resolveTabManager(routing: routing) else {
            return nil
        }

        // Int64 → Int is lossless on 64-bit macOS.
        let sequence = Int(max(0, CmuxEventBus.shared.latestSequence))
        let selectedWorkspaceId = tabManager.selectedTabId
        let workspaces = tabManager.tabs.enumerated().map { index, workspace in
            extensionSidebarWorkspaceRow(
                workspace: workspace,
                index: index,
                selected: workspace.id == tabManager.selectedTabId
            )
        }
        return ControlExtensionSidebarSnapshot(
            sequence: sequence,
            windowID: AppDelegate.shared?.windowId(for: tabManager),
            selectedWorkspaceID: selectedWorkspaceId,
            workspaces: workspaces
        )
    }

    /// The byte-faithful twin of the former
    /// `v2ExtensionSidebarWorkspacePayload`, producing a Sendable row.
    private func extensionSidebarWorkspaceRow(
        workspace: Workspace,
        index: Int,
        selected: Bool
    ) -> ControlExtensionSidebarWorkspace {
        let latestNotificationText = TerminalNotificationStore.shared.latestNotification(forTabId: workspace.id).flatMap {
            let text = $0.body.isEmpty ? $0.title : $0.body
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        let presentedDirectory = workspace.presentedCurrentDirectory ?? ""
        let trimmedPresentedDirectory = presentedDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        return ControlExtensionSidebarWorkspace(
            workspaceID: workspace.id,
            index: index,
            title: workspace.title,
            description: workspace.customDescription,
            isSelected: selected,
            isPinned: workspace.isPinned,
            rootPath: trimmedPresentedDirectory.isEmpty ? nil : trimmedPresentedDirectory,
            projectRootPath: workspace.extensionSidebarProjectRootPath,
            branchSummary: workspace.sidebarGitBranchesInDisplayOrder().first?.branch,
            remoteDisplayTarget: workspace.remoteDisplayTarget,
            remoteConnectionStateRawValue: workspace.remoteConnectionState.rawValue,
            remotePayload: JSONValue(foundationObject: workspace.remoteStatusPayload()) ?? .object([:]),
            currentDirectory: presentedDirectory,
            customColor: workspace.customColor,
            unreadCount: TerminalNotificationStore.shared.unreadCount(forTabId: workspace.id),
            latestNotificationText: latestNotificationText,
            latestConversationMessage: workspace.latestConversationMessage,
            latestSubmittedMessage: workspace.latestSubmittedMessage,
            latestSubmittedAtISO: workspace.latestSubmittedAt.map(CmuxEventBus.isoTimestamp),
            listeningPorts: workspace.listeningPorts,
            pullRequestURLs: workspace.sidebarPullRequestsInDisplayOrder().map { $0.url.absoluteString },
            panelDirectories: workspace.sidebarFilesystemDirectoriesInDisplayOrder(),
            gitBranches: workspace.sidebarGitBranchesInDisplayOrder().map {
                ControlExtensionSidebarWorkspace.GitBranch(branch: $0.branch, isDirty: $0.isDirty)
            }
        )
    }

    // MARK: - split_off (bridge to the still-shared v2SurfaceSplitOff)

    func controlSurfaceSplitOff(params: [String: JSONValue]) -> ControlCallResult {
        // `v2SurfaceSplitOff` stays in TerminalController+MoveTabToNewWorkspace
        // (shared with the v1 `drag_surface_to_split`). Forward the raw params
        // and bridge its Foundation result, exactly as `surface.move` does.
        let foundationParams = params.mapValues(\.foundationObject)
        switch v2SurfaceSplitOff(params: foundationParams) {
        case let .ok(payload):
            return .ok(JSONValue(foundationObject: payload) ?? .object([:]))
        case let .err(code, message, data):
            return .err(code: code, message: message, data: data.flatMap { JSONValue(foundationObject: $0) })
        }
    }

#if DEBUG
    // MARK: - mobile.dev_stack_auth.configure (DEBUG)

    func controlMobileDevStackAuthSetToken(_ token: String?) {
        MobileHostService.shared.debugConfigureAcceptedStackAuthTokenForTesting(token)
    }
#endif
}

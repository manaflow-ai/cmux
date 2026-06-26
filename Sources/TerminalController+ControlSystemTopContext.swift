import AppKit
import Bonsplit
import CmuxControlSocket
import Foundation

/// The `system.top` / `system.memory` window- and workspace-node witnesses: the
/// byte-faithful live-state tree walk of the former
/// `TerminalController.v2TopWindowNode` / `v2TopWorkspaceNode` / `v2TopTagNodes`,
/// producing the Sendable ``ControlSystemTopWindowNode`` /
/// ``ControlSystemTopWorkspaceNode`` instead of payload dictionaries. The
/// coordinator shapes the node into the payload via
/// ``ControlCommandCoordinator/systemTopWindowPayload(_:)`` /
/// ``ControlCommandCoordinator/systemTopWorkspacePayload(_:)``; the app bridges
/// that JSON value back to a `[String: Any]` dictionary so the nonisolated
/// `system.top` process-annotation pipeline keeps consuming the same dict tree.
///
/// The dict shaping (including the window/selected-workspace ref minting and the
/// tag id/ref percent-escaping) moved into the package; only the live
/// `AppDelegate` / `TabManager` / `Workspace` / `BrowserPanel` reads stay here.
extension TerminalController {

    func controlSystemTopWorkspaceNode(
        workspaceID: UUID,
        index: Int,
        selected: Bool
    ) -> ControlSystemTopWorkspaceNode? {
        guard let app = AppDelegate.shared else { return nil }
        for summary in app.listMainWindowSummaries() {
            guard let manager = app.tabManagerFor(windowId: summary.windowId) else { continue }
            if let workspace = manager.tabs.first(where: { $0.id == workspaceID }) {
                return systemTopWorkspaceNode(workspace: workspace, index: index, selected: selected)
            }
        }
        return nil
    }

    /// Builds the `system.top` payload dictionary for one window, byte-faithful
    /// to the former `v2TopWindowNode`: wraps the live window summary plus the
    /// typed workspace nodes into a ``ControlSystemTopWindowNode``, shapes it
    /// through the coordinator, then bridges the JSON value back to a Foundation
    /// dictionary for the worker-lane annotation pipeline.
    func v2TopWindowNode(
        summary: AppDelegate.MainWindowSummary,
        index: Int,
        workspaceNodes: [ControlSystemTopWorkspaceNode]
    ) -> [String: Any] {
        let node = ControlSystemTopWindowNode(
            summary: systemTopWindowSummary(summary),
            index: index,
            workspaces: workspaceNodes
        )
        let payload = controlCommandCoordinator.systemTopWindowPayload(node)
        // The shaped payload is always a JSON object; `.foundationObject` of an
        // object is a `[String: Any]`, so this cast never fails for valid input.
        return (payload.foundationObject as? [String: Any]) ?? [:]
    }

    /// Bridges the app target's `AppDelegate.MainWindowSummary` into the package's
    /// ``ControlWindowSummary`` window header (the shared window-identity value
    /// type) for the `system.top` window node.
    private func systemTopWindowSummary(
        _ summary: AppDelegate.MainWindowSummary
    ) -> ControlWindowSummary {
        ControlWindowSummary(
            windowID: summary.windowId,
            isKeyWindow: summary.isKeyWindow,
            isVisible: summary.isVisible,
            workspaceCount: summary.workspaceCount,
            selectedWorkspaceID: summary.selectedWorkspaceId
        )
    }

    /// The byte-faithful twin of the former `v2TopWorkspaceNode` tree walk,
    /// producing a Sendable node instead of a payload dictionary. `internal`
    /// (not `private`): the `system.top` / `task-manager` entrypoints in
    /// `TerminalController.swift` build the per-window workspace-node lists from
    /// it directly.
    func systemTopWorkspaceNode(
        workspace: Workspace,
        index: Int,
        selected: Bool
    ) -> ControlSystemTopWorkspaceNode {
        var paneByPanelId: [UUID: UUID] = [:]
        var indexInPaneByPanelId: [UUID: Int] = [:]
        var selectedInPaneByPanelId: [UUID: Bool] = [:]

        let paneIds = workspace.bonsplitController.allPaneIds
        for paneId in paneIds {
            let tabs = workspace.bonsplitController.tabs(inPane: paneId)
            let selectedTab = workspace.bonsplitController.selectedTab(inPane: paneId)
            for (tabIndex, tab) in tabs.enumerated() {
                guard let panelId = workspace.panelIdFromSurfaceId(tab.id) else { continue }
                paneByPanelId[panelId] = paneId.id
                indexInPaneByPanelId[panelId] = tabIndex
                selectedInPaneByPanelId[panelId] = (tab.id == selectedTab?.id)
            }
        }

        var surfacesByPane: [UUID: [ControlSystemTopSurfaceNode]] = [:]
        let focusedSurfaceId = workspace.focusedPanelId
        for (surfaceIndex, panel) in orderedPanels(in: workspace).enumerated() {
            let paneUUID = paneByPanelId[panel.id]
            let selectedInPane = selectedInPaneByPanelId[panel.id] ?? false

            let isBrowser: Bool
            let browserURL: String?
            let browserWebContentPID: Int?
            let browserLifecycleStateRawValue: String?
            var webviews: [ControlSystemTopWebViewNode] = []

            if panel.panelType == .browser, let browserPanel = panel as? BrowserPanel {
                let webContentPID = CmuxWebContentProcessIdentifier.pid(for: browserPanel.webView)
                let url = browserPanel.currentURL?.absoluteString ?? ""
                isBrowser = true
                browserURL = url
                browserWebContentPID = webContentPID
                browserLifecycleStateRawValue = browserPanel.webViewLifecycleState.rawValue
                // The lifecycle payload is provably JSON-safe (strings, bools,
                // ints, NSNull, ISO timestamps), so the bridge never falls back.
                let lifecycle = JSONValue(foundationObject: browserPanel.webViewLifecycleTopPayload()) ?? .object([:])
                webviews = [
                    ControlSystemTopWebViewNode(
                        surfaceID: panel.id,
                        index: 0,
                        title: browserPanel.displayTitle,
                        url: url,
                        pid: webContentPID,
                        lifecycle: lifecycle
                    )
                ]
            } else {
                isBrowser = false
                browserURL = nil
                browserWebContentPID = nil
                browserLifecycleStateRawValue = nil
            }

            let node = ControlSystemTopSurfaceNode(
                surfaceID: panel.id,
                index: surfaceIndex,
                typeRawValue: panel.panelType.rawValue,
                title: workspace.panelTitle(panelId: panel.id) ?? panel.displayTitle,
                isFocused: panel.id == focusedSurfaceId,
                isSelected: selectedInPane,
                selectedInPane: selectedInPaneByPanelId[panel.id],
                paneID: paneUUID,
                indexInPane: indexInPaneByPanelId[panel.id],
                tty: workspace.surfaceTTYNames[panel.id],
                isBrowser: isBrowser,
                browserURL: browserURL,
                browserWebContentPID: browserWebContentPID,
                browserWebViewLifecycleStateRawValue: browserLifecycleStateRawValue,
                webviews: webviews
            )
            if let paneUUID {
                surfacesByPane[paneUUID, default: []].append(node)
            }
        }

        for paneUUID in surfacesByPane.keys {
            surfacesByPane[paneUUID]?.sort {
                ($0.indexInPane ?? $0.index) < ($1.indexInPane ?? $1.index)
            }
        }

        let focusedPaneId = workspace.bonsplitController.focusedPaneId
        let panes: [ControlSystemTopPaneNode] = paneIds.enumerated().map { paneIndex, paneId in
            let tabs = workspace.bonsplitController.tabs(inPane: paneId)
            let surfaceUUIDs: [UUID] = tabs.compactMap { workspace.panelIdFromSurfaceId($0.id) }
            let selectedTab = workspace.bonsplitController.selectedTab(inPane: paneId)
            let selectedSurfaceUUID = selectedTab.flatMap { workspace.panelIdFromSurfaceId($0.id) }

            return ControlSystemTopPaneNode(
                paneID: paneId.id,
                index: paneIndex,
                isFocused: paneId == focusedPaneId,
                surfaceIDs: surfaceUUIDs,
                selectedSurfaceID: selectedSurfaceUUID,
                surfaces: surfacesByPane[paneId.id] ?? []
            )
        }

        return ControlSystemTopWorkspaceNode(
            workspaceID: workspace.id,
            index: index,
            title: workspace.title,
            description: workspace.customDescription,
            isSelected: selected,
            isPinned: workspace.isPinned,
            panes: panes,
            tags: systemTopTagNodes(for: workspace)
        )
    }

    /// The byte-faithful twin of the former `v2TopTagNodes`, producing Sendable
    /// tag nodes (the coordinator mints the id/ref from the workspace id + key).
    private func systemTopTagNodes(for workspace: Workspace) -> [ControlSystemTopTagNode] {
        var tags: [ControlSystemTopTagNode] = []
        var seenKeys = Set<String>()

        for (index, entry) in workspace.sidebarStatusEntriesInDisplayOrder().enumerated() {
            let pid = workspace.agentPIDs[entry.key].flatMap { $0 > 0 ? Int($0) : nil }
            tags.append(
                ControlSystemTopTagNode(
                    workspaceID: workspace.id,
                    index: index,
                    key: entry.key,
                    value: entry.value,
                    icon: entry.icon,
                    color: entry.color,
                    url: entry.url?.absoluteString,
                    priority: entry.priority,
                    formatRawValue: entry.format.rawValue,
                    isVisible: true,
                    pid: pid
                )
            )
            seenKeys.insert(entry.key)
        }

        for key in workspace.agentPIDs.keys.sorted() where !seenKeys.contains(key) {
            let pid = workspace.agentPIDs[key].flatMap { $0 > 0 ? Int($0) : nil }
            tags.append(
                ControlSystemTopTagNode(
                    workspaceID: workspace.id,
                    index: tags.count,
                    key: key,
                    value: "",
                    icon: nil,
                    color: nil,
                    url: nil,
                    priority: 0,
                    formatRawValue: "plain",
                    isVisible: false,
                    pid: pid
                )
            )
        }

        return tags
    }
}

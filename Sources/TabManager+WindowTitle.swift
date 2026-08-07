import AppKit
import Foundation

extension TabManager {
    func refreshWindowTitle() {
        updateWindowTitleForSelectedTab()
    }

    func workspaceCurrentDirectoryDidChange(workspaceId: UUID) {
        guard workspaceId == selectedTabId else { return }
        refreshWindowTitle()
    }

    func updateWindowTitleForSelectedTab() {
        guard let selectedTabId,
              let tab = workspacesById[selectedTabId] else {
            updateWindowTitle(for: nil)
            return
        }
        updateWindowTitle(for: tab)
    }

    func updateWindowTitle(for tab: Workspace?) {
        let title = windowTitle(for: tab)
        guard let targetWindow = window else { return }
        targetWindow.title = title
    }

    /// The name to display for `tab` across window chrome — the custom title
    /// bar, `NSWindow.title`, and the toolbar command label.
    ///
    /// A workspace group's anchor is represented everywhere by the group itself
    /// (the sidebar draws only the group header, never a separate anchor row,
    /// per `SidebarWorkspaceRenderItem`), so for an anchor the single source of
    /// truth for the displayed name is the group's `name`. The anchor's own
    /// `title` is merely seeded equal to the group name at creation and would
    /// otherwise drift when the group is renamed.
    func resolvedWorkspaceDisplayTitle(for tab: Workspace) -> String {
        let anchorGroupName = workspaces.groupNamesByAnchorWorkspaceId[tab.id]
        return resolvedWorkspaceDisplayTitle(for: tab, anchorGroupName: anchorGroupName)
    }

    func resolvedWorkspaceDisplayTitle(forWorkspaceId workspaceId: UUID) -> String? {
        guard let workspace = workspacesById[workspaceId] else { return nil }
        return resolvedWorkspaceDisplayTitle(for: workspace)
    }

    func resolvedWorkspaceDisplayTitles(for workspaceIds: Set<UUID>) -> [UUID: String] {
        guard !workspaceIds.isEmpty else { return [:] }
        let groupNamesByAnchorId = workspaces.groupNamesByAnchorWorkspaceId
        var titles: [UUID: String] = [:]
        titles.reserveCapacity(workspaceIds.count)
        for workspaceId in workspaceIds {
            guard let workspace = workspacesById[workspaceId] else { continue }
            titles[workspaceId] = resolvedWorkspaceDisplayTitle(
                for: workspace,
                anchorGroupName: groupNamesByAnchorId[workspaceId]
            )
        }
        return titles
    }

    private func resolvedWorkspaceDisplayTitle(for workspace: Workspace, anchorGroupName: String?) -> String {
        anchorGroupName ?? workspace.title
    }

    private func windowTitle(for tab: Workspace?) -> String {
        let defaultTitle = defaultWindowTitle(for: tab)
        guard let windowId, let template = WindowTitleTemplate.configured() else { return defaultTitle }

        let workspaceTitle = tab.map {
            resolvedWorkspaceDisplayTitle(for: $0)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } ?? ""
        let activeDirectory = activeWindowTitleDirectory(for: tab)
        let resolvedTitle = template.resolved(context: WindowTitleTemplateContext(
            defaultTitle: defaultTitle,
            activeWorkspace: workspaceTitle.isEmpty ? defaultTitle : workspaceTitle,
            activeDirectory: activeDirectory,
            windowId: windowId,
            appName: "cmux"
        ))
        let trimmedResolvedTitle = resolvedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedResolvedTitle.isEmpty ? defaultTitle : trimmedResolvedTitle
    }

    private func defaultWindowTitle(for tab: Workspace?) -> String {
        guard let tab else { return "cmux" }
        let trimmedTitle = resolvedWorkspaceDisplayTitle(for: tab).trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTitle.isEmpty { return trimmedTitle }
        let trimmedDirectory = activeWindowTitleDirectory(for: tab)
        return trimmedDirectory.isEmpty ? "cmux" : trimmedDirectory
    }

    private func activeWindowTitleDirectory(for tab: Workspace?) -> String {
        guard let tab else { return "" }
        if let focusedPanelId = tab.focusedPanelId,
           tab.allowsLocalDirectoryFallback(panelId: focusedPanelId) {
            return trimmedWindowTitleDirectory(tab.reportedPanelDirectory(panelId: focusedPanelId))
                ?? trimmedWindowTitleDirectory(tab.terminalPanel(for: focusedPanelId)?.requestedWorkingDirectory)
                ?? (tab.isRemoteWorkspace ? "" : trimmedWindowTitleDirectory(tab.presentedCurrentDirectory) ?? "")
        }
        return trimmedWindowTitleDirectory(tab.presentedCurrentDirectory) ?? ""
    }

    private func trimmedWindowTitleDirectory(_ directory: String?) -> String? {
        let trimmed = directory?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

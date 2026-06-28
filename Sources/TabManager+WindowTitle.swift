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
              let tab = tabs.first(where: { $0.id == selectedTabId }) else {
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
        if let group = workspaceGroups.first(where: { $0.anchorWorkspaceId == tab.id }) {
            return group.name
        }
        return tab.title
    }

    private func windowTitle(for tab: Workspace?) -> String {
        withRemoteHostPrefix(baseWindowTitle(for: tab), tab: tab)
    }

    /// Prefixes a display title with the remote tmux host name when `tab` is a
    /// mirror, so windows/chrome that hold (or aggregate) remote sessions are
    /// identifiable: "host — workspace". Used by the NSWindow title (Window menu /
    /// Mission Control) and cmux's own title bar + command label.
    func withRemoteHostPrefix(_ title: String, tab: Workspace?) -> String {
        guard let tab, tab.isRemoteTmuxMirror,
              let host = AppDelegate.shared?.remoteTmuxController.remoteTmuxHost(forWorkspaceId: tab.id)
        else { return title }
        let destination = host.destination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !destination.isEmpty else { return title }
        return title.isEmpty ? destination : "\(destination) \u{2014} \(title)"
    }

    private func baseWindowTitle(for tab: Workspace?) -> String {
        let defaultTitle = defaultWindowTitle(for: tab)
        guard let windowId, let template = WindowTitleTemplate.configured() else { return defaultTitle }

        let workspaceTitle = tab.map {
            resolvedWorkspaceDisplayTitle(for: $0)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } ?? ""
        let activeDirectory = tab?.currentDirectory.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
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
        let trimmedDirectory = tab.currentDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedDirectory.isEmpty ? "cmux" : trimmedDirectory
    }
}

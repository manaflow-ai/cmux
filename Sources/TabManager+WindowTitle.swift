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
    func resolvedWorkspaceDisplayTitle(for tab: Workspace) -> String {
        return tab.title
    }

    private func windowTitle(for tab: Workspace?) -> String {
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

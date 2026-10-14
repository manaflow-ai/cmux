import CmuxNextBridge
import CmuxNextDaemon
import Foundation

/// Reads what `WorkspaceAutoName` needs from the app's live sources: the
/// setting, the Debug Settings variant and a front tab's names. Reading in an
/// observation tracks each source, so the sidebar row and the one-time
/// rename follow a chat getting its title, a page loading or a terminal's
/// title changing.
@MainActor
struct WorkspaceAutoNameReader {
    let services: AppServices

    /// The rule as `workspaces.autoName` and `workspaces.autoName.variant` set it now.
    var rule: WorkspaceAutoName {
        WorkspaceAutoName(enabled: services.settings?.snapshot.sidebarSections.autoNamesWorkspaces ?? true,
                          variant: WorkspaceAutoNameTunables.variant.value)
    }

    /// What `tab` gives a workspace it fronts: an agent chat its chat's
    /// title (none for a New Tab page), a browser its page's, a terminal
    /// what a workspace made from it would take (`TabMoves.nameInput`). A
    /// page, app or Home conversation tab gives nothing (nil): its record is
    /// titled `about:blank`.
    func front(_ tab: TabModel) -> WorkspaceAutoName.Front? {
        if let session = tab.agentSession {
            if RestoredNewTabPages.shows(tab, in: services.agentTabs) { return .chat(userName: nil, title: nil) }
            return .chat(userName: tab.name, title: AgentTurnStateStore.shared.title(for: session))
        }
        if tab.kind == .conversation || tab.page != nil || tab.appTab != nil { return nil }
        guard tab.kind == .browser else { return .terminal(TabMoves.nameInput(tab, services: services)) }
        if services.cache.browserTabs.isIncognitoTab(tab.id) {
            return .browser(title: services.cache.incognitoDisplay(tab).title, offTheRecord: true)
        }
        return .browser(title: pageTitle(tab), offTheRecord: false)
    }

    /// A browser tab's title as a workspace name: the tab's user name, else
    /// its page title (live, else recorded) unless it only repeats the
    /// address, else its host without `www.` (`NewWorkspaceName.forTab`).
    private func pageTitle(_ tab: TabModel) -> String? {
        func clean(_ text: String?) -> String? {
            let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? nil : trimmed
        }
        if let name = clean(tab.name) { return name }
        let page = services.cache.existingBrowser(tab.id)?.tab.state
        let url = page?.url ?? tab.url.flatMap(URL.init(string:))
        for candidate in [page?.title, tab.title] {
            guard let title = clean(candidate), title != clean(url?.absoluteString), title != clean(tab.url) else { continue }
            return title
        }
        return url?.host().map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 }
    }
}

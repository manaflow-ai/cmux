public import CmuxNextBridge
public import CmuxNextDaemon
public import Foundation

/// Reads what `WorkspaceAutoName` needs from the app's live sources: the
/// setting, the Debug Settings variant and a front tab's names. Reading in an
/// observation tracks each source, so the sidebar row and the one-time
/// rename follow a chat getting its title, a page loading or a terminal's
/// title changing. The app supplies what only it knows: the setting, its New
/// Tab pages, its rendered browser pages and `TabMoves.nameInput`.
@MainActor
public struct WorkspaceAutoNameReader {
    /// A browser tab's live page, when the app renders it.
    public typealias LivePage = (title: String?, url: URL?)

    /// `workspaces.autoName`.
    let enabled: @MainActor () -> Bool
    /// Whether an agent tab still shows the New Tab page.
    let isNewTabPage: @MainActor (TabModel) -> Bool
    let livePage: @MainActor (TabModel) -> LivePage?
    /// An incognito browser tab's in-memory title; nil for a tab that is not incognito.
    let incognitoTitle: @MainActor (TabModel) -> String??
    /// What `NewWorkspaceName` reads of a terminal tab.
    let terminal: @MainActor (TabModel) -> NewWorkspaceName.Tab
    let turns: AgentTurnStateStore

    /// - Parameters:
    ///   - enabled: `workspaces.autoName`.
    ///   - isNewTabPage: whether an agent tab still shows the New Tab page.
    ///   - livePage: a browser tab's rendered page.
    ///   - incognitoTitle: an incognito tab's title (`.some`), nil for other tabs.
    ///   - terminal: a terminal tab as `NewWorkspaceName` reads it.
    ///   - turns: the chat titles (`AgentTurnStateStore.shared`).
    public init(enabled: @escaping @MainActor () -> Bool, isNewTabPage: @escaping @MainActor (TabModel) -> Bool,
                livePage: @escaping @MainActor (TabModel) -> LivePage?, incognitoTitle: @escaping @MainActor (TabModel) -> String??,
                terminal: @escaping @MainActor (TabModel) -> NewWorkspaceName.Tab, turns: AgentTurnStateStore = .shared) {
        self.enabled = enabled
        self.isNewTabPage = isNewTabPage
        self.livePage = livePage
        self.incognitoTitle = incognitoTitle
        self.terminal = terminal
        self.turns = turns
    }

    /// The rule as `workspaces.autoName` and `workspaces.autoName.variant` set it now.
    public var rule: WorkspaceAutoName {
        WorkspaceAutoName(enabled: enabled(), variant: WorkspaceAutoNameTunables.variant.value)
    }

    /// The name the sidebar row of `workspace` shows while `tab` fronts it
    /// (`WorkspaceAutoName.label`). `work` is the tab a browser front tab
    /// yields its name to (`SidebarMapping.workTab`).
    public func label(_ workspace: WorkspaceModel, front tab: TabModel, work: TabModel?) -> String? {
        rule.label(name: workspace.name, title: workspace.title, front: front(tab), anchor: work.flatMap { front($0) })
    }

    /// What `tab` gives a workspace it fronts: an agent chat its chat's
    /// title (none for a New Tab page), a browser its page's, a terminal
    /// what a workspace made from it would take. A page, app or Home
    /// conversation tab gives nothing (nil): its record is titled `about:blank`.
    public func front(_ tab: TabModel) -> WorkspaceAutoName.Front? {
        if let session = tab.agentSession {
            if isNewTabPage(tab) { return .chat(userName: nil, title: nil) }
            return .chat(userName: tab.name, title: turns.title(for: session), generatedTitle: turns.generatedTitle(for: session))
        }
        if tab.kind == .conversation || tab.page != nil || tab.appTab != nil { return nil }
        guard tab.kind == .browser else { return .terminal(terminal(tab)) }
        if let incognito = incognitoTitle(tab) { return .browser(title: incognito, offTheRecord: true) }
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
        let page = livePage(tab)
        let url = page?.url ?? tab.url.flatMap(URL.init(string:))
        for candidate in [page?.title, tab.title] {
            guard let title = clean(candidate), title != clean(url?.absoluteString), title != clean(tab.url) else { continue }
            return title
        }
        return url?.host().map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 }
    }
}

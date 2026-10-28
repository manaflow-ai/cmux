public import CmuxNextBridge
public import CmuxNextDaemon
public import Foundation

/// Reads what `WorkspaceAutoName` needs from the app's live sources: the
/// setting, the Debug Settings variant and a front tab's names. Reading in an
/// observation tracks each source, so the sidebar row and the persisted
/// name follow a chat getting its title, a page loading or a terminal's
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
    /// The last name each row's front tab gave it.
    let hold: WorkspaceAutoNameHold
    /// Whether an old daemon's missing provenance may use `~` or an empty name as automatic.
    let allowsLegacyDefaults: @MainActor (WorkspaceModel) -> Bool

    /// - Parameters:
    ///   - enabled: `workspaces.autoName`.
    ///   - isNewTabPage: whether an agent tab still shows the New Tab page.
    ///   - livePage: a browser tab's rendered page.
    ///   - incognitoTitle: an incognito tab's title (`.some`), nil for other tabs.
    ///   - terminal: a terminal tab as `NewWorkspaceName` reads it.
    ///   - turns: the chat titles (`AgentTurnStateStore.shared`).
    ///   - hold: the names rows keep while their front tab's is unknown; the
    ///     app's one (`AppServices.autoNameHold`), since it builds a reader per row it maps.
    public init(enabled: @escaping @MainActor () -> Bool, isNewTabPage: @escaping @MainActor (TabModel) -> Bool,
                livePage: @escaping @MainActor (TabModel) -> LivePage?, incognitoTitle: @escaping @MainActor (TabModel) -> String??,
                terminal: @escaping @MainActor (TabModel) -> NewWorkspaceName.Tab, turns: AgentTurnStateStore = .shared,
                hold: WorkspaceAutoNameHold, allowsLegacyDefaults: @escaping @MainActor (WorkspaceModel) -> Bool = { _ in true }) {
        self.enabled = enabled
        self.isNewTabPage = isNewTabPage
        self.livePage = livePage
        self.incognitoTitle = incognitoTitle
        self.terminal = terminal
        self.turns = turns
        self.hold = hold
        self.allowsLegacyDefaults = allowsLegacyDefaults
    }

    /// The rule as `workspaces.autoName` and `workspaces.autoName.variant` set it now.
    public var rule: WorkspaceAutoName {
        WorkspaceAutoName(enabled: enabled(), variant: WorkspaceAutoNameTunables.variant.value)
    }

    /// The name the sidebar row of `workspace` shows while `tab` fronts it
    /// (`WorkspaceAutoName.label`). `work` is the tab a browser front tab
    /// yields its name to (`SidebarMapping.workTab`).
    ///
    /// The same front tab that named the row keeps naming it while its own
    /// name is briefly unknown (`WorkspaceAutoNameHold`): a chat whose title
    /// the turn store has not read yet (a relaunch, a watch reconnect, a tree
    /// resync) never drops the row back to the daemon's `workspace-N`.
    public func label(_ workspace: WorkspaceModel, front tab: TabModel, work: TabModel?) -> String? {
        let rule = self.rule
        let legacyDefaults = self.allowsLegacyDefaults(workspace)
        let label = rule.label(name: workspace.name, title: workspace.title, front: front(tab), anchor: work.flatMap { front($0) },
                               nameSource: workspace.nameSource, nameRevision: workspace.nameRevision,
                               allowsLegacyDefaults: legacyDefaults)
        guard rule.enabled, !WorkspaceAutoName.isUserNamed(name: workspace.name, title: workspace.title,
                                                           nameSource: workspace.nameSource, nameRevision: workspace.nameRevision,
                                                           allowsLegacyDefaults: legacyDefaults) else {
            hold.forget(workspace: workspace.id)
            return label
        }
        return hold.settle(workspace: workspace.id, namer: Self.namer(tab, work: work), label: label)
    }

    /// What names a row: the tab (with the chat it shows, so a new chat in the same tab starts
    /// unnamed) and the work tab a browser front tab yields to.
    private static func namer(_ tab: TabModel, work: TabModel?) -> String {
        [tab, work].map { tab in tab.map { $0.id + "@" + ($0.agentSession?.session ?? "") } ?? "" }.joined(separator: "|")
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

    /// The name a workspace made from `tab` takes (`TabMoves.toNewWorkspace`: a drag, a tear-off
    /// into its own window, Move Pane): an agent chat its user name, else its chat's real title
    /// (none for a New Tab page or a chat titled only by its first prompt: a name written now
    /// lasts, so those keep the daemon's name and read as the chat live, `displayName`), any
    /// other tab what `NewWorkspaceName.forTab` gives it. A chat tab's record carries no title or
    /// folder, so read as a terminal it named nothing and the window read "workspace-41".
    public func newWorkspaceName(_ tab: TabModel) -> String? {
        guard let session = tab.agentSession else { return NewWorkspaceName.forTab(terminal(tab)) }
        if isNewTabPage(tab) { return nil }
        return NewWorkspaceName.clean(tab.name) ?? NewWorkspaceName.clean(turns.generatedTitle(for: session))
    }

    /// What a window's titlebar names `workspace`, whose front tab is `front`: its sidebar row's
    /// name (`AppServices.sidebarPageFace`), so while it keeps the daemon's default name it reads
    /// as its front tab (as `work`, the row's work tab, while the front is a page beside it),
    /// else its own name.
    public func displayName(_ workspace: WorkspaceModel, front: TabModel?, work: TabModel? = nil) -> String {
        guard let front else { return workspace.displayName }
        return label(workspace, front: front, work: work) ?? workspace.displayName
    }

    /// What a window's titlebar names `workspace`, whose panes show the tabs `selectedTab` picks
    /// (the window's selection): `displayName` for the front and work tabs its sidebar row reads
    /// (`SidebarMapping.row`): its agent chat while the front is an idle shell (`labelTab`).
    public func titlebarName(_ workspace: WorkspaceModel, selectedTab: (PaneModel) -> String?) -> String {
        let mapping = SidebarMapping.shared, tabs = workspace.screens.flatMap(\.panes).flatMap(\.tabs)
        let front = mapping.labelTab(mapping.frontTab(workspace, selectedTab: selectedTab), tabs,
                                     newTabPages: Set(tabs.filter { isNewTabPage($0) }.map(\.id)))
        let work = front?.kind == .browser ? SidebarMapping.shared.workTab(workspace, selectedTab: selectedTab) : nil
        return displayName(workspace, front: front, work: work)
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

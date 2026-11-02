import CmuxNextActions
import CmuxNextDaemon
import Foundation
import CmuxNextPalette

/// Search All Windows (⌥⌘F): opens a palette page that searches as you type
/// across every tab on every machine, in all windows and in workspaces no
/// window shows: tab titles and places, terminal history and screens, and
/// the transcripts of Claude Code and Codex sessions running in terminals
/// on this Mac. An optional `text` argument (the CLI's) is the starting
/// query. Choosing a match shows its tab, and for terminal text runs Find
/// there for the match.
enum GlobalSearchHandlers {
    static func bind(into registry: ActionRegistry, context ctx: AppActionContext) {
        registry.bind("globalSearch", invoke: { invocation in
            let query = invocation["text"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let tabs = searchable(ctx.services.machines.allWorkspaces, titles: TabTitleResolver(services: ctx.services))
            guard !tabs.isEmpty else { return ctx.refuse(GlobalSearchStrings.noTabs) }
            let page = GlobalSearchPage.page(query: query, tabs: tabs) { located, needle in
                show(located, find: needle, registry, ctx)
            }
            ctx.services.palette.show(page: page, relativeTo: ctx.activeWindow?.window)
        })
    }

    /// Selects the match's tab in the window showing (or taking) its
    /// workspace, brings that window forward, and runs Find there for a
    /// needle. A workspace no window showed mounts later, so Find waits for it.
    private static func show(_ located: LocatedTab, find needle: String?, _ registry: ActionRegistry, _ ctx: AppActionContext) {
        guard ActionRunScope.viewChangeAllowed(), let controller = ctx.window(showing: located.workspace.id) else { return }
        controller.state.selection.select(located.tab.id, in: located.pane.id)
        ctx.services.windows.bringToFront(controller)
        guard let needle, !needle.isEmpty else { return }
        let find = {
            let target = ActionInvocation(target: ActionTargetRef(kind: .tab, id: located.tab.id), arguments: ["text": .string(needle)])
            _ = registry.perform("find", invocation: target)
        }
        if ctx.services.paneController(for: located.pane) != nil { return find() }
        ctx.services.windows.afterNextContent(in: controller, showing: located.workspace.id, find)
    }

    /// Every live tab, in workspace, screen, pane and tab order. A terminal
    /// whose daemon is connected is read; a remote-terminal tab is searched
    /// by title only (its text lives in another session, which its own tab
    /// there covers). A terminal agent's transcript is read when the agent
    /// runs on this Mac. Tabs are named by `titles`, the strip's rule: an
    /// agent chat by its chat, never the `about:blank` its record carries.
    static func searchable(_ workspaces: [(WorkspaceModel, DaemonService)], titles: TabTitleResolver) -> [GlobalSearchPage.Tab] {
        var result: [GlobalSearchPage.Tab] = []
        var titles = titles
        for (workspace, daemon) in workspaces {
            let connection = daemon.connection
            titles.workspaceName = AgentChatTabTitle.workspaceName(workspace)
            for screen in workspace.screens {
                for pane in screen.panes {
                    for tab in pane.tabs where !tab.dead {
                        let isTerminal = tab.kind == .pty && tab.remote == nil
                        let terminal = isTerminal ? connection.map {
                            TerminalTextSearch.Target(tabID: tab.id, surface: tab.surface, connection: $0)
                        } : nil
                        let name = titles.title(tab)
                        let source = GlobalSearchCorpus.Source(
                            tabID: tab.id, title: searchText(name, of: tab, in: workspace), terminal: terminal,
                            agent: isTerminal && daemon.isLocal ? agentSession(of: tab) : nil,
                            disconnected: isTerminal && terminal == nil, local: daemon.isLocal)
                        result.append(GlobalSearchPage.Tab(source: source, title: name,
                                                           located: LocatedTab(tab: tab, pane: pane, workspace: workspace)))
                    }
                }
            }
        }
        return result
    }

    /// The text a title match looks in: the tab's shown title, its
    /// workspace's name, and a browser's address. Not a terminal's folder
    /// (the shown title of one its shell has not titled): one folder word
    /// would match every terminal opened there.
    private static func searchText(_ title: String, of tab: TabModel, in workspace: WorkspaceModel) -> String {
        let name = tab.agentSession == nil && (tab.kind == .pty || tab.kind == .remoteTerminal) ? tab.displayTitle : title
        return [name, workspace.displayName, tab.kind == .browser ? tab.url : nil].compactMap { $0 }.joined(separator: " ")
    }

    private static func agentSession(of tab: TabModel) -> AgentTranscriptText.Session? {
        guard let status = tab.agent, let harness = TerminalChatRoute.harness(of: status.agent),
              let sessionID = status.harnessSessionID else { return nil }
        return AgentTranscriptText.Session(harness: harness, sessionID: sessionID, cwd: tab.cwd)
    }
}

import CmuxNextActions
import CmuxNextDaemon
import Foundation

/// Search All Windows (⌥⌘F): the query's words across the text of every
/// terminal on every machine, in all windows and in workspaces no window
/// shows. The old app searched live as you typed; here the query is the
/// action's text argument (the palette asks for it inline from the menu or
/// shortcut, the CLI passes it) and the matches open as a palette page.
/// Choosing one shows its terminal and runs Find there for the match.
enum GlobalSearchHandlers {
    static func bind(into registry: ActionRegistry, context ctx: AppActionContext) {
        registry.bind("globalSearch", invoke: { invocation in
            guard let query = invocation["text"]?.stringValue
                .flatMap({ $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 })
                ?? ctx.refuse(RefusalStrings.textArgumentRequired) else { return }
            let terminals = searchable(ctx.services.machines.allWorkspaces)
            guard !terminals.isEmpty else { return ctx.refuse(GlobalSearchStrings.noTerminals) }
            let page = GlobalSearchPage.page(query: query, terminals: terminals) { located, needle in
                show(located, find: needle, registry, ctx)
            }
            ctx.services.palette.show(page: page, relativeTo: ctx.activeWindow?.window)
        })
    }

    /// Selects the match's tab in the window showing (or taking) its
    /// workspace, brings that window forward, and runs Find there. A
    /// workspace no window showed mounts later, so Find waits for it.
    private static func show(_ located: LocatedTab, find needle: String, _ registry: ActionRegistry, _ ctx: AppActionContext) {
        guard ViewChangePolicy.allowed(), let controller = ctx.window(showing: located.workspace.id) else { return }
        controller.state.selection.select(located.tab.id, in: located.pane.id)
        ctx.services.windows.bringToFront(controller)
        let find = {
            let target = ActionInvocation(target: ActionTargetRef(kind: .tab, id: located.tab.id),
                                          arguments: needle.isEmpty ? [:] : ["text": .string(needle)])
            _ = registry.perform("find", invocation: target)
        }
        if ctx.services.paneController(for: located.pane) != nil { return find() }
        ctx.services.windows.afterNextContent(in: controller, showing: located.workspace.id, find)
    }

    /// Live terminal tabs whose daemon is connected, in workspace, screen,
    /// pane and tab order. A remote-terminal tab is skipped: its text lives
    /// in another session, which its own tab there covers.
    static func searchable(_ workspaces: [(WorkspaceModel, DaemonService)]) -> [GlobalSearchPage.Terminal] {
        var result: [GlobalSearchPage.Terminal] = []
        for (workspace, daemon) in workspaces {
            guard let connection = daemon.connection else { continue }
            for screen in workspace.screens {
                for pane in screen.panes {
                    for tab in pane.tabs where tab.kind == .pty && tab.remote == nil && !tab.dead {
                        result.append(GlobalSearchPage.Terminal(
                            target: TerminalTextSearch.Target(tabID: tab.id, surface: tab.surface, connection: connection),
                            located: LocatedTab(tab: tab, pane: pane, workspace: workspace)))
                    }
                }
            }
        }
        return result
    }
}

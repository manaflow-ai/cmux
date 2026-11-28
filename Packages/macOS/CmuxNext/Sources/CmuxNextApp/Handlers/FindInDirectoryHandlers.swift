import CmuxNextActions
import CmuxNextDaemon
import Foundation

/// Find in Directory (⇧⌘F): ripgrep over the targeted terminal's working
/// directory. The old app showed matches in the right sidebar's Find mode;
/// cmux-next has no right sidebar, so the query is the action's text
/// argument (the palette asks for it inline from the menu or shortcut, the
/// CLI passes it) and the matches open as a palette page.
enum FindInDirectoryHandlers {
    static func bind(into registry: ActionRegistry, context ctx: AppActionContext) {
        registry.bind("findInDirectory", invoke: { invocation in
            guard let query = invocation["text"]?.stringValue
                .flatMap({ $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 })
                ?? ctx.refuse(RefusalStrings.textArgumentRequired) else { return }
            guard let (tab, pane) = ctx.daemonTab(invocation) else { return }
            guard tab.kind == .pty else { return ctx.refuse(RefusalStrings.notATerminal) }
            // rg runs here, so a Cloud or SSH terminal's directory is out of reach.
            guard ctx.services.daemon(for: pane).isLocal else { return ctx.refuse(FindInDirectoryStrings.localOnly) }
            guard let root = tab.cwd ?? ctx.refuse(RefusalStrings.noWorkingDirectory) else { return }
            guard let rg = RipgrepSearch.executable() ?? ctx.refuse(FindInDirectoryStrings.ripgrepMissing) else { return }
            let target = ActionInvocation(target: ActionTargetRef(kind: .tab, id: tab.id))
            let page = FindInDirectoryPage.page(query: query, root: root, rg: rg) { text in
                TerminalHandlers.send(text, paste: true, target, ctx)
            }
            ctx.services.palette.show(page: page, relativeTo: ctx.activeWindow?.window)
        })
    }
}

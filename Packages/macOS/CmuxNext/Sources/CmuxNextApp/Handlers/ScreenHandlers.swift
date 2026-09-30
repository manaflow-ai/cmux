import CmuxNextActions
import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextLayout

/// Screen actions (tmux-style windows inside a workspace): create, switch,
/// rename, close. The switcher strip stays hidden unless the user toggles
/// it for the window's current workspace view.
enum ScreenHandlers {
    static func bind(into registry: ActionRegistry, context ctx: AppActionContext) {
        registry.bind("screen.new", invoke: { _ in
            guard let content = ctx.content(), let connection = ctx.connection() else { return }
            let workspace = content.workspace.handle
            let intent = content.beginFocusIntent()
            Task {
                do {
                    let created = try await connection.newScreen(in: workspace)
                    content.expectFocus(on: created.surface, generation: intent)
                } catch {
                    ctx.services.daemon.logger.error("new-screen failed: \(String(describing: error), privacy: .public)")
                }
            }
        })
        registry.bind("screen.next", invoke: { _ in selectAdjacent(forward: true, ctx) })
        registry.bind("screen.previous", invoke: { _ in selectAdjacent(forward: false, ctx) })
        registry.bind("screen.select", invoke: { invocation in
            guard let content = ctx.content() else { return }
            guard let number = invocation["index"]?.intValue ?? ctx.refuse(RefusalStrings.indexRequired) else { return }
            let screens = content.layoutModel.screens
            guard screens.indices.contains(number - 1) else { return ctx.refuse(RefusalStrings.screenCount(screens.count)) }
            select(screens[number - 1].id, in: content)
        })
        registry.bind("screen.rename", invoke: { invocation in
            guard let (_, screen) = screen(invocation, ctx) else { return }
            let handle = screen.handle
            if let name = invocation["name"]?.stringValue {
                ctx.send("rename-screen") { try await $0.renameScreen(handle, to: name) }
                return
            }
            guard let window = ctx.services.windows.active?.window ?? ctx.refuse(RefusalStrings.noWindowForRename) else { return }
            RenamePrompt.run(title: HandlerStrings.renameScreenTitle, initial: screen.name ?? "", in: window) { name in
                ctx.send("rename-screen") { try await $0.renameScreen(handle, to: name) }
            }
        })
        registry.bind("screen.close", invoke: { invocation in
            guard let (_, screen) = screen(invocation, ctx) else { return }
            let handle = screen.handle
            ctx.send("close-screen") { try await $0.closeScreen(handle) }
        })
        registry.bind("screen.toggleSwitcher", invoke: { _ in
            guard let content = ctx.content() else { return }
            content.layoutModel.showsScreenSwitcher.toggle()
        })
    }

    /// The targeted screen (`screen:<id>`), else the focused view's active screen.
    private static func screen(_ invocation: ActionInvocation, _ ctx: AppActionContext) -> (WorkspaceModel, ScreenModel)? {
        if let target = invocation.target, target.kind == .screen {
            for workspace in ctx.services.activeDaemon.store.workspaces {
                if let screen = workspace.screens.first(where: { $0.id == target.id }) { return (workspace, screen) }
            }
            return ctx.refuse(RefusalStrings.noScreen(target.id))
        }
        guard let content = ctx.content() else { return nil }
        let active = content.layoutModel.activeScreenID?.rawValue
        guard let screen = content.workspace.screens.first(where: { $0.id == active }) ?? content.workspace.screens.first
            ?? ctx.refuse(RefusalStrings.workspaceHasNoScreen) else { return nil }
        return (content.workspace, screen)
    }

    private static func selectAdjacent(forward: Bool, _ ctx: AppActionContext) {
        guard let content = ctx.content() else { return }
        let screens = content.layoutModel.screens
        guard screens.count > 1 else { return ctx.refuse(RefusalStrings.workspaceHasOneScreen) }
        let index = screens.firstIndex { $0.id == content.layoutModel.activeScreenID } ?? 0
        select(screens[(index + (forward ? 1 : -1) + screens.count) % screens.count].id, in: content)
    }

    /// Shows the screen and focuses its first pane through `LayoutModel.focus`,
    /// so the window's remembered focus moves too (else the next store update
    /// would restore focus, and the screen, from before the switch).
    private static func select(_ id: LayoutScreenID, in content: WorkspaceContentController) {
        content.layoutModel.selectScreen(id)
        guard let pane = content.layoutModel.screens.first(where: { $0.id == id })?.layout.panes.first else { return }
        PaneHandlers.focus(pane, in: content)
    }
}

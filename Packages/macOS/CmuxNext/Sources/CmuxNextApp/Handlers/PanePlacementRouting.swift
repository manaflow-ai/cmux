import CmuxNextActions
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextLayout
import CmuxNextSettings

/// Zellij-style new panes (`PanePlacement`): New Pane (Auto Layout)
/// (Ctrl-Cmd-N) splits the largest scrolling pane on screen along its
/// longer side, never a docked column. With `layout.newPanePlacement:
/// split`, a person's New Terminal (and New Browser, with
/// `layout.tileBrowsers`) takes the same path. Scripts (CLI, MCP) always get
/// a tab, so their result stays predictable; a run that names a pane opens
/// exactly there.
enum PanePlacementRouting {
    enum Route {
        /// Open as a tab in this pane.
        case tab(PaneModel)
        /// Open as a new pane splitting this one toward the direction.
        case split(PaneModel, PaneDirection)
    }

    /// The pane New Pane (Auto Layout) splits from `focused`: the largest
    /// scrolling pane on its screen; `focused` itself when the run names a
    /// pane or the screen has no scrolling pane.
    static func autoLayoutTarget(_ ctx: AppActionContext, _ invocation: ActionInvocation,
                                 from focused: PaneController) -> PaneController {
        guard !ctx.namesPane(invocation), let content = focused.workspace,
              let screen = content.layoutModel.screen(containing: focused.layoutPaneID),
              let pick = PanePlacement().autoSplit(layout: screen.layout, frames: content.layoutView.navigationFrames,
                                                   recent: content.recentPanes),
              let target = content.panes[pick.pane] else { return focused }
        return target
    }

    /// The split direction for a new pane in `pane`: its longer side first
    /// (right on a tie), the other axis when only it has room. Nil when
    /// neither has room.
    static func autoLayoutDirection(_ ctx: AppActionContext, _ pane: PaneController) -> (preferred: PaneDirection, fitting: PaneDirection?) {
        let frame = pane.workspace?.layoutView.frame(of: pane.layoutPaneID) ?? .zero
        let preferred: PaneDirection = frame.width >= frame.height ? .right : .down
        let other: PaneDirection = preferred == .right ? .down : .right
        let fitting = [preferred, other].first { direction in
            if case .split = ctx.services.splitRoom(for: pane.pane, edge: PaneHandlers.edge(direction)) { true } else { false }
        }
        return (preferred, fitting)
    }

    /// The route for a new tab of a kind that tiles (`tiles`: a terminal,
    /// or a browser with `layout.tileBrowsers`) opened from `pane`. A tab
    /// in `pane` unless a person asked for split placement and a pane has
    /// room to split.
    static func route(_ ctx: AppActionContext, _ invocation: ActionInvocation, from pane: PaneModel, tiles: Bool) -> Route {
        guard invocation.origin == .user, !ctx.namesPane(invocation), let focused = ctx.services.paneController(for: pane),
              let content = focused.workspace,
              let screen = content.layoutModel.screen(containing: focused.layoutPaneID) else { return .tab(pane) }
        let placement = ctx.services.settings?.snapshot.newPanePlacement ?? CmuxConfigSnapshot.newPanePlacementFallback
        let plan = PanePlacement().plan(layout: screen.layout, focused: focused.layoutPaneID, recent: content.recentPanes,
                                        frames: content.layoutView.navigationFrames, placement: placement, tiles: tiles)
        guard case .split(let target, _) = plan, let controller = content.panes[target],
              let direction = autoLayoutDirection(ctx, controller).fitting else { return .tab(pane) }
        return .split(controller.pane, direction)
    }

    /// Whether `layout.tileBrowsers` lets a person's new browser split.
    static func browsersTile(_ ctx: AppActionContext) -> Bool {
        ctx.services.settings?.snapshot.tileBrowsers ?? CmuxConfigSnapshot.tileBrowsersFallback
    }

    /// The invocation aimed at `pane`, keeping its arguments and origin. A
    /// new terminal opens where the person works (NEW-TERMINAL-INHERITS-CWD):
    /// without a `cwd` argument, the folder of `focused`'s selected terminal.
    /// Any other focused tab leaves the split's own fallback (the target
    /// pane's folder).
    static func aimed(_ invocation: ActionInvocation, at pane: PaneModel, from focused: PaneController?) -> ActionInvocation {
        var aimed = invocation
        aimed.target = ActionTargetRef(kind: .pane, id: pane.id)
        if aimed["cwd"]?.stringValue == nil, let tab = focused?.selectedTab, tab.kind == .pty, let cwd = tab.cwd {
            aimed.arguments["cwd"] = .string(cwd)
        }
        return aimed
    }

    /// Moves a new tab (a tiled browser) out of `pane` into a new pane
    /// toward `direction`. It stays a tab when the pane has no room.
    static func moveToSplit(_ ctx: AppActionContext, _ surface: SurfaceID, of pane: PaneModel, direction: PaneDirection) {
        guard case .split = ctx.services.splitRoom(for: pane, edge: PaneHandlers.edge(direction)),
              let connection = ctx.services.daemon(for: pane).connection else { return }
        let handle = pane.handle
        let daemonDirection: SplitDirection = direction == .right ? .right : .down
        ctx.registry.track(Task {
            do {
                _ = try await connection.split(handle, direction: daemonDirection, movingTab: surface)
                return nil
            } catch {
                return "move-tab-to-split: \(error)"
            }
        })
    }
}

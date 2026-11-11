import AppKit
import CmuxNextActions
import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextDaemonService
import CmuxNextDesign
import CmuxNextLayout

// Swap, close, rename, flash and workspace font size.
extension PaneHandlers {
    static func bindPaneVerbs(into registry: ActionRegistry, context ctx: AppActionContext) {
        bindSwaps(registry, ctx)
        bindLifecycle(registry, ctx)
        bindFontSize(registry, ctx)
    }

    private static func bindSwaps(_ registry: ActionRegistry, _ ctx: AppActionContext) {
        let swaps: [(ActionID, LayoutDirection, PaneDirection)] = [
            ("swapPaneLeft", .left, .left), ("swapPaneRight", .right, .right), ("swapPaneUp", .up, .up), ("swapPaneDown", .down, .down),
        ]
        for (id, side, direction) in swaps {
            registry.bindEffect(id, effect: { invocation in
                guard let pane = ctx.daemonPane(invocation) else { return .done }
                // The window the key went to, else one that shows the pane; none (a scripted run on a hidden workspace): a model change only, on the daemon's event.
                guard let shown = ctx.services.windows.active?.focusedPane.flatMap({ $0.pane === pane ? $0 : nil }) ?? ctx.services.paneController(for: pane), let content = shown.workspace else { return ctx.services.daemon(for: pane).swapEffect(pane.handle, toward: direction) }
                // With the pane the screen shows on that side (Focus Pane Left's rule, on the displayed frames): the swap seen is the swap sent.
                guard let other = neighbor(of: shown.layoutPaneID, direction: side, in: content).flatMap({ content.panes[$0] }) else { return .refused(RefusalStrings.noPaneInDirection(RefusalStrings.direction(side)), quiet: true) }
                return showNow(ctx, pane) { $0.swapEffect(pane.handle, with: other.pane.handle, toward: direction) }
            })
        }
        // Also what a pane drag's drop runs (PaneSwapDrag).
        registry.bindEffect("palette.swapWithSession", effect: { invocation in
            guard let source = ctx.paneController(ActionInvocation(target: invocation.target).onMachine(invocation.targetMachineID))?.pane else { return .done }
            guard let ref = invocation["pane"]?.targetValue else { return .refused(RefusalStrings.paneArgumentRequired) }
            // In the source's own daemon, from its index: both handles are one daemon's, and no walk of the session.
            guard let target = ctx.services.daemon(for: source).store.pane(idOrResource: ref.id) else { return .refused(RefusalStrings.noPaneID(ref.id)) }
            guard target !== source else { return .refused(RefusalStrings.paneCannotSwapWithItself, quiet: true) }
            return showNow(ctx, source) { $0.swapEffect(source.handle, with: target.handle) }
        })
    }

    /// Runs a zoom or a swap of `pane` on its own daemon (a store intent), then lays out each window that shows its workspace
    /// in the same turn, not a turn later on the store's observation. A workspace no window shows takes the model change only;
    /// one parked off screen lays out once, when it shows (`WorkspaceContentController.apply`).
    // perf-hot: 10ms pane-verb-turn
    static func showNow(_ ctx: AppActionContext, _ pane: PaneModel, _ change: (DaemonService) -> ActionEffect) -> ActionEffect {
        let daemon = ctx.services.daemon(for: pane), effect = change(daemon)
        guard let workspace = daemon.store.workspace(containing: pane.handle) else { return effect }
        for window in ctx.services.windows.controllers where window.content?.workspace === workspace { window.content?.applyLayoutIfChanged() }
        return effect
    }

    private static func bindLifecycle(_ registry: ActionRegistry, _ ctx: AppActionContext) {
        registry.bind("closePane", invoke: { invocation in
            // While the focus a split asked for is on its way, the focused pane is its new pane: the
            // split is cancelled, never the old pane closed (CancelledCreation); so is a provisional pane named.
            // Either way the window drops the stand-in and the focus goes to a live pane in this turn (showCancelledCreation).
            if invocation.target == nil, let content = ctx.focusedContent, case .tab(let id)? = content.focus.state.expectation?.key, content.daemon.cancelSplit(showing: id) { ctx.services.keyRouter.creationInputCoordinator.drop(tab: id, in: content.contentView.window); return content.showCancelledCreation() }
            guard let pane = ctx.daemonPane(invocation) else { return }
            if let opening = ctx.services.daemon(for: pane).cancelCreation(showing: pane) { let shown = ctx.services.paneController(for: pane); opening.forEach { ctx.services.keyRouter.creationInputCoordinator.drop(tab: $0, in: shown?.view.window) }; shown?.workspace?.showCancelledCreation(); return }
            // A person's close in the Home Chief pane keeps the pane and says why; the CLI and MCP
            // still ask and get the daemon's `dock-column-pinned` refusal (home-chief-pane.md).
            if invocation.origin == .user, ctx.services.paneController(for: pane)?.isPinnedDockPane == true {
                return ctx.refuse(MiscHandlerStrings.homeChiefPaneStays)
            }
            let handle = pane.handle
            // The pane leaves its window now and its neighbours spring into its space
            // (close-animation DESIGN.md); a refused close brings it back.
            let controller = ctx.services.paneController(for: pane)
            // The pane's own daemon decides: a remote pane's close waits for no local connection.
            let shown = ctx.services.daemon(for: pane).connection == nil ? nil : controller?.showPaneClose()
            // The pane's own daemon closes it (`DaemonService.closePane`): a stand-in still opening leaves the records in
            // this turn, never refused ("This pane is still opening", Leo 2026-11-03: "i should be able to just close
            // immedeiately"), and its close waits for the daemon's pane that takes it over.
            ctx.services.daemon(for: pane).closePane(handle) { failed in controller?.finishPaneClose(shown, failed: failed) }
        })
        // Every other pane of the right-clicked pane's screen closes with its
        // tabs, as a user's tab close does: no question, the closed history
        // keeps them and an undo toast offers them back (cx-k9go).
        registry.bind("pane.closeOthers", invoke: { invocation in
            guard let pane = ctx.daemonPane(invocation) else { return }
            let screens = ctx.services.machines.daemons.lazy.flatMap(\.store.workspaces).flatMap(\.screens)
            let screen = screens.first { $0.panes.contains { $0 === pane } }
            // The Home Chief pane (a pinned dock) never closes: Close Other Panes leaves it out
            // rather than asking the daemon for a refusal (home-chief-pane.md).
            let kept = Set((screen?.columns ?? []).filter { $0.dock?.isPinned == true }.flatMap(\.layout.paneIDs))
            let others = (screen?.panes ?? []).filter { $0 !== pane && !kept.contains($0.handle) }
            guard !others.isEmpty else { return ctx.refuse(HandlerStrings.noOtherPanes) }
            // Read before the close: the closing panes leave the layout at once, and a pane looked up
            // after it has no view and got a second close the daemon refused (`unknown pane`).
            let shown = others.compactMap { ctx.services.paneController(for: $0) }
            let unshown = others.filter { ctx.services.paneController(for: $0) == nil }
            // One gesture: one question, one toast decision and one closed group over every closing tab (cx-lb4al).
            CloseUndoToasts.close(shown.map { (pane: $0, ids: $0.stripModel.orderedTabs.map(\.id)) })
            for other in unshown {
                let handle = other.handle
                ctx.send("close-pane") { try await $0.closePane(handle) }
            }
        })
        // The name shows in the input's turn (a store intent); a refusal puts the old one back.
        registry.bindEffect("renamePane", effect: { invocation in
            guard let pane = ctx.daemonPane(invocation) else { return .done }
            let handle = pane.handle
            if let name = invocation["name"]?.stringValue {
                guard ctx.connection() != nil else { return .done }
                return ctx.daemon.intentEffect("rename-pane", .renamePane(pane: handle, name: name)) { try await $0.renamePane(handle, to: name) }
            }
            ctx.services.registry.ask("renamePane", invocation, ActionArgumentAsk(argument: "name", initialText: pane.name ?? ""))
            return .done
        })
        registry.bind("triggerFlash", invoke: { invocation in
            guard let pane = ctx.paneController(invocation) else { return }
            pane.view.flashRing()
        })
    }

    /// Ghostty font size bindings on every live terminal in the workspace.
    /// Terminals released from the surface cache start at the configured size.
    private static func bindFontSize(_ registry: ActionRegistry, _ ctx: AppActionContext) {
        let bindings: [(ActionID, String)] = [
            ("increaseWorkspaceTerminalFontSize", "increase_font_size:1"),
            ("decreaseWorkspaceTerminalFontSize", "decrease_font_size:1"),
            ("resetWorkspaceTerminalFontSize", "reset_font_size"),
        ]
        for (id, binding) in bindings {
            registry.bind(id, invoke: { invocation in
                guard let content = ctx.content(invocation) else { return }
                var applied = 0
                for pane in content.panes.values {
                    if case .terminal(let entry) = pane.currentContent, entry.session.surfaceView.performBindingAction(binding) {
                        applied += 1
                    }
                }
                if applied == 0 { ctx.refuse(RefusalStrings.noLiveTerminal) }
            })
        }
    }
}

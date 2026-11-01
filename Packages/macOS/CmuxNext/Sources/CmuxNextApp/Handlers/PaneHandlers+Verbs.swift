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
        let swaps: [(ActionID, PaneDirection)] = [
            ("swapPaneLeft", .left), ("swapPaneRight", .right), ("swapPaneUp", .up), ("swapPaneDown", .down),
        ]
        for (id, direction) in swaps {
            registry.bind(id, invoke: { invocation in
                guard let pane = ctx.daemonPane(invocation) else { return }
                let handle = pane.handle
                ctx.send("swap-pane") { try await $0.swapPane(handle, with: .direction(direction)) }
            })
        }
        registry.bind("palette.swapWithSession", invoke: { invocation in
            guard let source = ctx.paneController(ActionInvocation(target: invocation.target))?.pane else { return }
            guard let ref = invocation["pane"]?.targetValue ?? ctx.refuse(RefusalStrings.paneArgumentRequired) else { return }
            let panes = ctx.services.activeDaemon.store.workspaces.flatMap(\.screens).flatMap(\.panes)
            guard let target = panes.first(where: { $0.id == ref.id }) ?? ctx.refuse(RefusalStrings.noPaneID(ref.id)) else { return }
            guard target !== source else { return ctx.refuseQuietly(RefusalStrings.paneCannotSwapWithItself) }
            let from = source.handle, to = target.handle
            ctx.send("swap-pane") { try await $0.swapPane(from, with: .pane(to)) }
        })
    }

    private static func bindLifecycle(_ registry: ActionRegistry, _ ctx: AppActionContext) {
        registry.bind("closePane", invoke: { invocation in
            // While the focus a split asked for is on its way, the focused pane is its new pane: the
            // split is cancelled, never the old pane closed (CancelledCreation); so is a provisional pane named.
            // Either way the window drops the stand-in and the focus goes to a live pane in this turn (showCancelledCreation).
            if invocation.target == nil, let content = ctx.focusedContent, case .tab(let id)? = content.focus.state.expectation?.key, content.daemon.cancelSplit(showing: id) { ctx.services.keyRouter.creationInputCoordinator.drop(tab: id, in: content.contentView.window); return content.showCancelledCreation() }
            guard let pane = ctx.daemonPane(invocation) else { return }
            if ctx.services.daemon(for: pane).cancelCreation(pane: pane.handle) { ctx.services.paneController(for: pane)?.workspace?.showCancelledCreation(); return }
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
            ctx.send("close-pane") { connection in
                do {
                    try await connection.closePane(handle)
                    await MainActor.run { controller?.finishPaneClose(shown, failed: false) }
                } catch {
                    await MainActor.run { controller?.finishPaneClose(shown, failed: true) }
                    throw error
                }
            }
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
            flash(pane.view)
        })
    }

    /// A brief gray ring over the pane (no accent color): two blinks
    /// (`Motion.flashAnimation`), one fade under Reduce Motion, none when
    /// animations are off.
    private static func flash(_ view: NSView) {
        guard let host = view.layer, let fade = Motion.indicators.flashAnimation() else { return }
        let ring = CALayer()
        ring.frame = host.bounds.insetBy(dx: 2, dy: 2)
        ring.cornerRadius = 8
        let color = view.performWithTheme { Palette.focusRing }
        if Borders.drawsLines {
            ring.borderWidth = 3
            ring.borderColor = color.cgColor
        } else {
            // appearance.borders none: a soft fill instead of an outline.
            ring.backgroundColor = color.withAlphaComponent(0.18).cgColor
        }
        ring.opacity = 0
        host.addSublayer(ring)
        CATransaction.begin()
        CATransaction.setCompletionBlock { ring.removeFromSuperlayer() }
        ring.add(fade, forKey: "flash")
        CATransaction.commit()
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

import AppKit
import CmuxNextActions
import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextLayout

// Swap, close, rename, flash, workspace font size, and pane kinds this
// build does not have (simulator, sidebar-as-pane), which are bound
// with a typed reason instead of left unbound.
extension PaneHandlers {
    static func bindPaneVerbs(into registry: ActionRegistry, context ctx: AppActionContext) {
        bindSwaps(registry, ctx)
        bindLifecycle(registry, ctx)
        bindFontSize(registry, ctx)
        bindUnported(registry)
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
            if invocation.target == nil, let content = ctx.focusedContent, case .tab(let id)? = content.focus.state.expectation?.key, content.daemon.cancelSplit(showing: id) { return ctx.services.keyRouter.creationInputCoordinator.drop(tab: id, in: content.contentView.window) }
            guard let pane = ctx.daemonPane(invocation), !ctx.services.daemon(for: pane).cancelCreation(pane: pane.handle) else { return }
            let handle = pane.handle
            // The pane leaves its window now and its neighbours spring into its space
            // (close-animation DESIGN.md); a refused close brings it back.
            let controller = ctx.services.paneController(for: pane)
            let shown = ctx.services.activeDaemon.connection == nil ? nil : controller?.showPaneClose()
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
            let others = (screens.first { $0.panes.contains { $0 === pane } }?.panes ?? []).filter { $0 !== pane }
            guard !others.isEmpty else { return ctx.refuse(HandlerStrings.noOtherPanes) }
            // One gesture: one question and one toast decision over every closing tab (cx-lb4al).
            CloseUndoToasts.close(others.compactMap { ctx.services.paneController(for: $0) }.map { (pane: $0, ids: $0.stripModel.orderedTabs.map(\.id)) })
            for other in others where ctx.services.paneController(for: other) == nil {
                let handle = other.handle
                ctx.send("close-pane") { try await $0.closePane(handle) }
            }
        })
        registry.bind("renamePane", invoke: { invocation in
            guard let pane = ctx.daemonPane(invocation) else { return }
            let handle = pane.handle
            if let name = invocation["name"]?.stringValue {
                ctx.send("rename-pane") { try await $0.renamePane(handle, to: name) }
                return
            }
            guard let window = ctx.services.windows.active?.window ?? ctx.refuse(RefusalStrings.noWindowForRename) else { return }
            RenamePrompt.run(title: HandlerStrings.renamePaneTitle, initial: pane.name ?? "", in: window) { name in
                ctx.send("rename-pane") { try await $0.renamePane(handle, to: name) }
            }
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
        guard let host = view.layer, let fade = Motion.flashAnimation() else { return }
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

    private static func bindUnported(_ registry: ActionRegistry) {
        let simulator = RefusalStrings.simulatorUnported
        // palette.newSimulatorPane opens the phone tab (PhoneHandlers). The keyboard-only simulator
        // actions wait for a focused-phone context (simulatorFocused; plans/cmux-next/simulators-DESIGN.md).
        for id: ActionID in ["simulatorHome", "simulatorRotateLeft", "simulatorRotateRight",
                             "simulatorToggleAppearance", "simulatorToggleSoftwareKeyboard"] {
            registry.bindUnavailable(id, reason: simulator)
        }
        registry.bindUnavailable("palette.openFilesPane", reason: RefusalStrings.filesPaneUnported)
        registry.bindUnavailable("palette.openFindPane", reason: RefusalStrings.findPaneUnported)
    }
}

import AppKit
import CmuxNextActions
import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextLayout

// Swap, close, rename, flash, workspace font size, and pane kinds this
// build does not have (canvas, simulator, sidebar-as-pane), which are bound
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
            guard target !== source else { return ctx.refuse(RefusalStrings.paneCannotSwapWithItself) }
            let from = source.handle, to = target.handle
            ctx.send("swap-pane") { try await $0.swapPane(from, with: .pane(to)) }
        })
    }

    private static func bindLifecycle(_ registry: ActionRegistry, _ ctx: AppActionContext) {
        registry.bind("closePane", invoke: { invocation in
            guard let pane = ctx.daemonPane(invocation) else { return }
            let handle = pane.handle
            ctx.send("close-pane") { try await $0.closePane(handle) }
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

    /// A brief gray ring over the pane (no accent color), faded by Core
    /// Animation; Reduce Motion shortens it to a plain fade.
    private static func flash(_ view: NSView) {
        guard let host = view.layer else { return }
        let ring = CALayer()
        ring.frame = host.bounds.insetBy(dx: 2, dy: 2)
        ring.borderWidth = 3
        ring.cornerRadius = 8
        ring.borderColor = NSColor.labelColor.withAlphaComponent(0.45).cgColor
        ring.opacity = 0
        host.addSublayer(ring)
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        fade.values = reduceMotion ? [1, 0] : [0, 1, 1, 0, 1, 0]
        fade.duration = reduceMotion ? 0.35 : 0.9
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
        let canvas = RefusalStrings.canvasUnported
        for id: ActionID in ["toggleCanvasLayout", "canvasOverview", "canvasTidy", "canvasRevealFocusedPane", "canvasZoomIn",
                             "canvasZoomOut", "canvasZoomReset", "canvasAlignLeft", "canvasAlignRight", "canvasAlignTop",
                             "canvasAlignBottom", "canvasEqualizeWidths", "canvasEqualizeHeights",
                             "canvasDistributeHorizontally", "canvasDistributeVertically"] {
            registry.bindUnavailable(id, reason: canvas)
        }
        let simulator = RefusalStrings.simulatorUnported
        for id: ActionID in ["palette.newSimulatorPane", "simulatorHome", "simulatorRotateLeft", "simulatorRotateRight",
                             "simulatorToggleAppearance", "simulatorToggleSoftwareKeyboard"] {
            registry.bindUnavailable(id, reason: simulator)
        }
        registry.bindUnavailable("palette.openFilesPane", reason: RefusalStrings.filesPaneUnported)
        registry.bindUnavailable("palette.openFindPane", reason: RefusalStrings.findPaneUnported)
        registry.bindUnavailable("palette.openVaultPane", reason: RefusalStrings.vaultPaneUnported)
        registry.bindUnavailable("palette.openCloudPane", reason: RefusalStrings.cloudPaneUnported)
    }
}

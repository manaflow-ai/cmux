import CmuxNextActions
import CmuxNextBridge
import CmuxNextLayout

/// Canvas layout actions (plans/cmux-next/canvas-layout.md): a screen shown as
/// free-placed panes on a zoomable, pannable plane. Each action resolves the
/// targeted or focused pane's workspace and runs one `LayoutModel` method, the
/// one path the palette, keyboard, menus, CLI and MCP `action.run` share.
enum CanvasHandlers {
    static func bind(into registry: ActionRegistry, context ctx: AppActionContext) {
        registry.bind("toggleCanvasLayout", invoke: { invocation in
            guard let (content, pane) = target(invocation, ctx) else { return }
            toggle(content, pane: pane, ctx)
        })
        registry.bind("canvasZoomIn", invoke: { zoom($0, by: CanvasCamera.zoomStep, ctx) })
        registry.bind("canvasZoomOut", invoke: { zoom($0, by: 1 / CanvasCamera.zoomStep, ctx) })
        registry.bind("canvasZoomReset", invoke: { invocation in
            guard let (content, pane) = canvasTarget(invocation, ctx) else { return }
            if !content.layoutModel.resetCanvasZoom(containing: pane) { ctx.refuseQuietly(RefusalStrings.canvasZoomLimit) }
        })
    }

    /// Shows the pane's screen as a canvas that starts where its panes show
    /// now, or shows its daemon layout again.
    static func toggle(_ content: WorkspaceContentController, pane: LayoutPaneID, _ ctx: AppActionContext) {
        let model = content.layoutModel
        guard let screen = model.screen(containing: pane)?.id else { return ctx.refuse(RefusalStrings.noWindowShowsWorkspace) }
        let seed = content.layoutView.canvasSeed(for: screen)
        model.toggleCanvas(screen: screen, seed: seed?.frames ?? [:], viewport: seed?.viewport ?? .zero)
        content.layoutView.syncWithModel()
        ctx.services.canvasContextDidChange()
    }

    private static func zoom(_ invocation: ActionInvocation, by factor: Double, _ ctx: AppActionContext) {
        guard let (content, pane) = canvasTarget(invocation, ctx) else { return }
        if !content.layoutModel.zoomCanvas(by: factor, containing: pane) { ctx.refuseQuietly(RefusalStrings.canvasZoomLimit) }
    }

    /// The targeted or focused pane and the workspace showing it.
    static func target(_ invocation: ActionInvocation, _ ctx: AppActionContext) -> (WorkspaceContentController, LayoutPaneID)? {
        guard let pane = ctx.paneController(invocation) else { return nil }
        guard let content = pane.workspace else { return ctx.refuse(RefusalStrings.paneHasNoWorkspaceView(pane.paneKey)) }
        return (content, pane.layoutPaneID)
    }

    /// ``target(_:_:)`` when the pane's screen shows a canvas; refuses otherwise.
    static func canvasTarget(_ invocation: ActionInvocation, _ ctx: AppActionContext) -> (WorkspaceContentController, LayoutPaneID)? {
        guard let (content, pane) = target(invocation, ctx) else { return nil }
        guard content.layoutModel.canvasScreenID(containing: pane) != nil else { return ctx.refuse(RefusalStrings.canvasNotShown) }
        return (content, pane)
    }
}

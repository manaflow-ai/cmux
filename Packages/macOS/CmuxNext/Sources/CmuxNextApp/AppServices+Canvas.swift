import CmuxNextActions
import CmuxNextLayout

extension AppServices {
    /// Publishes `canvasLayout` to the action registry while the active
    /// window's active screen shows a canvas (plans/cmux-next/canvas-layout.md),
    /// so the canvas actions and their shortcuts apply there and nowhere else.
    /// An explicit pane target on a canvas screen implies it too
    /// (`WorkspaceSetVerbs`, `registry.targetContext`).
    func canvasContextDidChange() {
        var context = registry.context
        if windows.active?.content?.layoutModel.isCanvasActive == true {
            context.insert(.canvasLayout)
        } else {
            context.remove(.canvasLayout)
        }
        if registry.context != context { registry.context = context }
    }
}

import Foundation
import CmuxCanvas

/// Every user-invokable canvas operation, behind one shared entrypoint.
///
/// Keyboard shortcuts, the command palette, the View menu, and the
/// `canvas.*` debug-socket verbs all construct a `CanvasAction` and run it
/// through ``CanvasActionExecutor`` — no surface carries its own logic.
enum CanvasAction: Equatable {
    /// Toggle the workspace between split and canvas layout.
    case toggleLayout
    /// Scroll the focused pane fully into view.
    case revealFocusedPane
    /// Toggle the fit-all overview zoom.
    case toggleOverview
    /// Apply an alignment/distribution/tidy command to all panes.
    case alignment(CanvasAlignmentCommand)
}

/// Executes ``CanvasAction``s against a workspace. The single shared
/// execution path for every canvas entrypoint.
@MainActor
struct CanvasActionExecutor {
    let workspace: Workspace

    /// Runs the action. Returns `false` when the action does not apply
    /// (for example a canvas-only action while the workspace is in splits).
    @discardableResult
    func perform(_ action: CanvasAction) -> Bool {
        switch action {
        case .toggleLayout:
            workspace.toggleCanvasLayout()
            return true
        case .revealFocusedPane:
            guard workspace.layoutMode == .canvas,
                  let panelId = workspace.focusedPanelId else { return false }
            workspace.canvasModel.viewport?.revealPane(panelId, animated: true)
            return true
        case .toggleOverview:
            guard workspace.layoutMode == .canvas else { return false }
            workspace.canvasModel.viewport?.toggleOverview()
            return true
        case .alignment(let command):
            guard workspace.layoutMode == .canvas else { return false }
            let changed = workspace.canvasModel.applyAlignment(
                command,
                to: [],
                reference: workspace.focusedPanelId
            )
            if changed {
                workspace.canvasModel.viewport?.modelDidChangeExternally(animated: true)
            }
            return changed
        }
    }
}

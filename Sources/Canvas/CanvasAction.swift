import Foundation
import CmuxCanvas
import CmuxCanvasUI

/// Every user-invokable canvas operation, behind one shared entrypoint.
///
/// Keyboard shortcuts, the command palette, the View menu, and the
/// `canvas.*` debug-socket verbs all construct a `CanvasAction` and run it
/// through ``CanvasActionExecutor`` — no surface carries its own logic.
enum CanvasAction: Equatable {
    /// Toggle the workspace between split and canvas layout.
    case toggleLayout
    /// Toggle the workspace between split and zoomable split layout.
    case toggleZoomableSplitLayout
    /// Scroll the focused pane fully into view.
    case revealFocusedPane
    /// Toggle the fit-all overview zoom.
    case toggleOverview
    /// Zoom in one step, anchored at the viewport center.
    case zoomIn
    /// Zoom out one step, anchored at the viewport center.
    case zoomOut
    /// Return to 100% magnification.
    case zoomReset
    /// Apply an alignment/distribution/tidy command to all panes.
    case alignment(CanvasAlignmentCommand)
}

extension KeyboardShortcutSettings.Action {
    /// All shortcut actions that map onto canvas actions, in dispatch order.
    static let canvasActions: [KeyboardShortcutSettings.Action] = [
        .toggleCanvasLayout,
        .toggleZoomableSplitLayout,
        .canvasRevealFocusedPane,
        .canvasOverview,
        .canvasZoomIn,
        .canvasZoomOut,
        .canvasZoomReset,
        .canvasTidy,
        .canvasAlignLeft,
        .canvasAlignRight,
        .canvasAlignTop,
        .canvasAlignBottom,
        .canvasEqualizeWidths,
        .canvasEqualizeHeights,
        .canvasDistributeHorizontally,
        .canvasDistributeVertically,
    ]

    /// The canvas action this shortcut action runs, if any.
    var canvasAction: CanvasAction? {
        switch self {
        case .toggleCanvasLayout: return .toggleLayout
        case .toggleZoomableSplitLayout: return .toggleZoomableSplitLayout
        case .canvasRevealFocusedPane: return .revealFocusedPane
        case .canvasOverview: return .toggleOverview
        case .canvasZoomIn: return .zoomIn
        case .canvasZoomOut: return .zoomOut
        case .canvasZoomReset: return .zoomReset
        case .canvasTidy: return .alignment(.tidy)
        case .canvasAlignLeft: return .alignment(.alignLeft)
        case .canvasAlignRight: return .alignment(.alignRight)
        case .canvasAlignTop: return .alignment(.alignTop)
        case .canvasAlignBottom: return .alignment(.alignBottom)
        case .canvasEqualizeWidths: return .alignment(.equalizeWidths)
        case .canvasEqualizeHeights: return .alignment(.equalizeHeights)
        case .canvasDistributeHorizontally: return .alignment(.distributeHorizontally)
        case .canvasDistributeVertically: return .alignment(.distributeVertically)
        default: return nil
        }
    }
}

/// Executes ``CanvasAction``s against a workspace. The single shared
/// execution path for every canvas entrypoint.
@MainActor
struct CanvasActionExecutor {
    let workspace: Workspace

    /// One keyboard/palette zoom step (matches typical app zoom increments).
    static let zoomStepFactor: CGFloat = 1.25

    /// Runs the action. Returns `false` when the action does not apply
    /// (for example a canvas-only action while the workspace is in splits).
    @discardableResult
    func perform(_ action: CanvasAction) -> Bool {
        switch action {
        case .toggleLayout:
            workspace.toggleCanvasLayout()
            return true
        case .toggleZoomableSplitLayout:
            workspace.toggleZoomableSplitLayout()
            return true
        case .revealFocusedPane:
            guard let viewport = activeViewport,
                  let panelId = workspace.focusedPanelId else { return false }
            viewport.revealPane(panelId, animated: true)
            return true
        case .toggleOverview:
            guard let viewport = activeViewport else { return false }
            viewport.toggleOverview()
            return true
        case .zoomIn:
            guard let viewport = activeViewport else { return false }
            viewport.zoom(by: Self.zoomStepFactor)
            return true
        case .zoomOut:
            guard let viewport = activeViewport else { return false }
            viewport.zoom(by: 1 / Self.zoomStepFactor)
            return true
        case .zoomReset:
            guard let viewport = activeViewport else { return false }
            viewport.resetZoom()
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

    private var activeViewport: (any CanvasViewportControlling)? {
        switch workspace.layoutMode {
        case .canvas:
            workspace.canvasModel.viewport
        case .zoomableSplits:
            workspace.zoomableSplitViewport
        case .splits:
            nil
        }
    }
}

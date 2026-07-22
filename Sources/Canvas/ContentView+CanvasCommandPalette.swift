import CmuxCommandPalette
import Foundation

/// Command palette surface for canvas layout actions. Every command routes
/// through `CanvasActionExecutor`, the same path as shortcuts, the View
/// menu, and the canvas.* socket verbs.
extension ContentView {
    private static let canvasToggleEnabledArgument = CmuxActionArgumentDefinition(
        name: "enabled",
        valueType: .boolean,
        required: false
    )

    private static let canvasPaletteCommands: [(id: String, action: KeyboardShortcutSettings.Action, keywords: [String])] = [
        ("palette.canvas.toggleLayout", .toggleCanvasLayout, ["canvas", "layout", "freeform", "splits", "spatial"]),
        ("palette.canvas.revealFocusedPane", .canvasRevealFocusedPane, ["canvas", "reveal", "scroll", "pane", "view"]),
        ("palette.canvas.overview", .canvasOverview, ["canvas", "overview", "zoom", "fit", "all"]),
        ("palette.canvas.zoomIn", .canvasZoomIn, ["canvas", "zoom", "in", "magnify", "bigger"]),
        ("palette.canvas.zoomOut", .canvasZoomOut, ["canvas", "zoom", "out", "shrink", "smaller"]),
        ("palette.canvas.zoomReset", .canvasZoomReset, ["canvas", "zoom", "reset", "actual", "size", "100"]),
        ("palette.canvas.tidy", .canvasTidy, ["canvas", "tidy", "grid", "arrange", "clean"]),
        ("palette.canvas.alignLeft", .canvasAlignLeft, ["canvas", "align", "left", "edges"]),
        ("palette.canvas.alignRight", .canvasAlignRight, ["canvas", "align", "right", "edges"]),
        ("palette.canvas.alignTop", .canvasAlignTop, ["canvas", "align", "top", "edges"]),
        ("palette.canvas.alignBottom", .canvasAlignBottom, ["canvas", "align", "bottom", "edges"]),
        ("palette.canvas.equalizeWidths", .canvasEqualizeWidths, ["canvas", "equalize", "width", "same", "size"]),
        ("palette.canvas.equalizeHeights", .canvasEqualizeHeights, ["canvas", "equalize", "height", "same", "size"]),
        ("palette.canvas.distributeHorizontally", .canvasDistributeHorizontally, ["canvas", "distribute", "horizontal", "gap", "pack"]),
        ("palette.canvas.distributeVertically", .canvasDistributeVertically, ["canvas", "distribute", "vertical", "gap", "pack"]),
    ]

    static func commandPaletteCanvasCommandContributions() -> [CommandPaletteCommandContribution] {
        let subtitle = String(localized: "command.canvas.subtitle", defaultValue: "Canvas")
        return canvasPaletteCommands.map { command in
            CommandPaletteCommandContribution(
                commandId: command.id,
                title: { _ in command.action.label },
                subtitle: { _ in subtitle },
                keywords: command.keywords,
                arguments: command.action == .toggleCanvasLayout || command.action == .canvasOverview
                    ? [canvasToggleEnabledArgument]
                    : [],
                when: { snapshot in
                    guard snapshot.bool(CommandPaletteContextKeys.hasWorkspace) else { return false }
                    // The mode toggle is always offered; everything else is
                    // canvas-only.
                    return command.action == .toggleCanvasLayout
                        || snapshot.bool(CommandPaletteContextKeys.workspaceCanvasLayout)
                }
            )
        }
    }

    func registerCanvasCommandHandlers(
        _ registry: inout CommandPaletteHandlerRegistry,
        context: CommandPaletteActionContext
    ) {
        for command in Self.canvasPaletteCommands {
            guard let canvasAction = command.action.canvasAction else { continue }
            registry.register(commandId: command.id) { invocation in
                guard let workspace = context.workspace() else {
                    return .targetUnavailable
                }
                let executor = CanvasActionExecutor(workspace: workspace)
                if canvasAction == .toggleLayout {
                    let requestedEnabled = Self.commandPaletteCanvasRequestedEnabled(invocation)
                    if invocation.arguments[Self.canvasToggleEnabledArgument.name] != nil,
                       requestedEnabled == nil {
                        return .invalidArgumentValues([Self.canvasToggleEnabledArgument.name])
                    }
                    if let requestedEnabled,
                       (workspace.layoutMode == .canvas) == requestedEnabled {
                        return .completed
                    }
                }
                if canvasAction == .toggleOverview {
                    return Self.commandPaletteCanvasOverviewResult(
                        executor: executor,
                        targetPanelID: context.target.panelID,
                        invocation: invocation
                    )
                }
                let outcome = executor.performWithOutcome(
                    canvasAction,
                    targetPanelID: context.target.panelID
                )
                return Self.commandPaletteCanvasResult(outcome)
            }
        }
    }

    private static func commandPaletteCanvasRequestedEnabled(
        _ invocation: CmuxActionInvocation
    ) -> Bool? {
        invocation.bool(canvasToggleEnabledArgument.name)
    }

    private static func commandPaletteCanvasOverviewResult(
        executor: CanvasActionExecutor,
        targetPanelID: UUID?,
        invocation: CmuxActionInvocation
    ) -> CmuxActionExecutionResult {
        let requestedEnabled = commandPaletteCanvasRequestedEnabled(invocation)
        if invocation.arguments[canvasToggleEnabledArgument.name] != nil,
           requestedEnabled == nil {
            return .invalidArgumentValues([canvasToggleEnabledArgument.name])
        }
        return commandPaletteCanvasResult(
            executor.performOverview(
                enabled: requestedEnabled,
                targetPanelID: targetPanelID
            )
        )
    }

    static func commandPaletteCanvasResult(
        _ outcome: CanvasActionExecutor.Outcome
    ) -> CmuxActionExecutionResult {
        switch outcome {
        case .completed:
            return .completed
        case .notApplicable:
            return .failed(
                code: "not_applicable",
                message: String(
                    localized: "action.error.notApplicable",
                    defaultValue: "The action does not apply to the target's current state."
                )
            )
        case .targetUnavailable:
            return .targetUnavailable
        }
    }
}

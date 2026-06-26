import CmuxCommandPalette
import Foundation

/// Command palette surface for canvas layout actions. Every command routes
/// through `CanvasActionExecutor`, the same path as shortcuts, the View
/// menu, and the canvas.* socket verbs.
extension ContentView {
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
        CommandPaletteCanvasContributionProvider().build(
            commands: canvasPaletteCommands.map { command in
                CommandPaletteCanvasContributionProvider.Command(
                    commandId: command.id,
                    title: command.action.label,
                    keywords: command.keywords,
                    alwaysAvailable: command.action == .toggleCanvasLayout
                )
            },
            subtitle: String(localized: "command.canvas.subtitle", defaultValue: "Canvas")
        )
    }

    func registerCanvasCommandHandlers(_ registry: inout CommandPaletteHandlerRegistry) {
        for command in Self.canvasPaletteCommands {
            guard let canvasAction = command.action.canvasAction else { continue }
            registry.register(commandId: command.id) { [weak tabManager] in
                guard let workspace = tabManager?.selectedWorkspace else { return }
                CanvasActionExecutor(workspace: workspace).perform(canvasAction)
            }
        }
    }
}

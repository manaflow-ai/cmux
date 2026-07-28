import CmuxCommandPalette

/// The result synchronously completed by the targeted content view.
enum CommandPaletteControlRequestResult {
    case listed(
        target: CommandPaletteActionTarget,
        commands: [CommandPaletteControlRequestItem]
    )
    case ran(CommandPaletteControlRequestItem, result: CmuxActionExecutionResult)
    case configurationPending
    case configurationChanged
    case targetUnavailable
    case commandNotFound
}

import CmuxCommandPalette

/// The result synchronously completed by the targeted content view.
enum CommandPaletteControlRequestResult {
    case listed([CommandPaletteControlRequestItem])
    case ran(CommandPaletteControlRequestItem, result: CmuxActionExecutionResult)
    case commandNotFound
}

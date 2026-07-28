import CmuxControlSocket

@MainActor
enum ExactCommandPaletteTargetResolution {
    case windowNotFound
    case targetUnavailable
    case resolved(
        context: AppDelegate.MainWindowContext,
        target: CommandPaletteActionTarget,
        handler: (CommandPaletteControlRequest) -> Void
    )
}

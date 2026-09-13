import CmuxCommandPalette

extension ContentView {
    static func commandPaletteGuiModeContributions() -> [CommandPaletteCommandContribution] {
        [CommandPaletteCommandContribution(
            commandId: GuiModeWorkspaceCoordinator.commandPaletteCommandId,
            title: { _ in String(localized: "guiMode.command.title", defaultValue: "Open GUI Mode") },
            subtitle: { _ in String(localized: "guiMode.command.subtitle", defaultValue: "Workspace") },
            keywords: ["gui", "mode", "agent", "codex", "task"]
        )]
    }

    func registerGuiModeCommandPaletteHandler(_ registry: inout CommandPaletteHandlerRegistry) {
        registry.register(commandId: GuiModeWorkspaceCoordinator.commandPaletteCommandId) {
            _ = GuiModeWorkspaceCoordinator().createHomeWorkspace(in: tabManager)
        }
    }
}

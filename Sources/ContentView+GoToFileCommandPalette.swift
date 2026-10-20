import CmuxCommandPalette
import Foundation

extension ContentView {
    static func commandPaletteGoToFileContribution() -> CommandPaletteCommandContribution {
        CommandPaletteCommandContribution(
            commandId: "palette.goToFile",
            title: { _ in String(localized: "commandPalette.goToFile.title", defaultValue: "Go to File…") },
            subtitle: { _ in String(localized: "commandPalette.goToFile.subtitle", defaultValue: "Open a file in the focused pane") },
            keywords: ["file", "open", "quick", "quick open", "filename", "workspace"],
            dismissOnRun: false
        )
    }
}

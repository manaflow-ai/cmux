import AppKit
import CmuxCommandPalette

extension ContentView {
    func appendOpenFileInBrowserCommandContribution(
        to contributions: inout [CommandPaletteCommandContribution]
    ) {
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.openFileInBrowser",
                title: { _ in String(localized: "command.openFileInBrowser.title", defaultValue: "Open File in Browser") },
                subtitle: { _ in String(localized: "command.newBrowserTab.subtitle", defaultValue: "Tab") },
                keywords: ["open", "file", "browser", "html", "svg", "preview", "render"],
                when: {
                    $0.bool(CommandPaletteContextKeys.hasFocusedPanel)
                        && $0.bool(CommandPaletteContextKeys.panelHasBrowserOpenableFile)
                        && !$0.bool(CommandPaletteContextKeys.browserDisabled)
                }
            )
        )
    }

    func registerOpenFileInBrowserCommandHandler(_ registry: inout CommandPaletteHandlerRegistry) {
        registry.register(commandId: "palette.openFileInBrowser") {
            guard let panelContext = focusedPanelContext,
                  panelContext.workspace.openLocalFilePanelInBrowserToRight(panelId: panelContext.panelId) != nil else {
                NSSound.beep()
                return
            }
        }
    }
}

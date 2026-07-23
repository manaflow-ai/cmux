import AppKit
import CmuxCommandPalette

extension ContentView {
    static func commandPaletteSurfaceNavigationContributions()
        -> [CommandPaletteCommandContribution] {
        func constant(_ value: String) -> (CommandPaletteContextSnapshot) -> String {
            { _ in value }
        }

        let subtitle = constant(
            String(
                localized: "command.surfaceNavigation.subtitle",
                defaultValue: "Surface Navigation"
            )
        )
        var contributions = [
            CommandPaletteCommandContribution(
                commandId: "palette.nextTabInPane",
                title: constant(
                    String(
                        localized: "command.nextTabInPane.title",
                        defaultValue: "Next Tab in Pane"
                    )
                ),
                subtitle: subtitle,
                keywords: ["next", "tab", "pane"],
                when: { $0.bool(CommandPaletteContextKeys.hasFocusedPanel) }
            ),
            CommandPaletteCommandContribution(
                commandId: "palette.previousTabInPane",
                title: constant(
                    String(
                        localized: "command.previousTabInPane.title",
                        defaultValue: "Previous Tab in Pane"
                    )
                ),
                subtitle: subtitle,
                keywords: ["previous", "tab", "pane"],
                when: { $0.bool(CommandPaletteContextKeys.hasFocusedPanel) }
            ),
        ]
        contributions.append(contentsOf: SurfacePaneMovement.allCases.map { movement in
            CommandPaletteCommandContribution(
                commandId: movement.commandID,
                title: constant(movement.title),
                subtitle: subtitle,
                keywords: movement.keywords,
                when: { $0.bool(CommandPaletteContextKeys.hasFocusedPanel) }
            )
        })
        return contributions
    }

    func registerSurfaceNavigationCommandHandlers(
        _ registry: inout CommandPaletteHandlerRegistry
    ) {
        registry.register(commandId: "palette.nextTabInPane") {
            tabManager.selectNextSurface()
        }
        registry.register(commandId: "palette.previousTabInPane") {
            tabManager.selectPreviousSurface()
        }
        for movement in SurfacePaneMovement.allCases {
            registry.register(commandId: movement.commandID) {
                if AppDelegate.shared?.performSurfacePaneMovement(
                    movement,
                    tabManager: tabManager,
                    preferredWindow: observedWindow ?? NSApp.keyWindow ?? NSApp.mainWindow
                ) != true {
                    NSSound.beep()
                }
            }
        }
    }
}

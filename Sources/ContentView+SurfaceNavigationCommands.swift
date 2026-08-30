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
        _ registry: inout CommandPaletteHandlerRegistry,
        dock: DockSplitStore? = nil,
        dockPanelId: UUID? = nil,
        focusDock: @escaping () -> Bool,
        preferredWindow: @escaping () -> NSWindow?
    ) {
        // A Dock target is captured when the palette is presented. Keep that
        // presentation-time ownership stable for the lifetime of the command
        // handlers: a palette opened from the main workspace must not start
        // dispatching into a Dock merely because focus changes before the user
        // invokes a command. Conversely, a captured Dock must still be live and
        // focused when the command executes; otherwise fail closed instead of
        // mutating a stale/hidden split tree.
        let capturedDock = dock
        let resolvedDock: () -> DockSplitStore? = {
            guard let capturedDock else { return nil }
            guard let app = AppDelegate.shared,
                  let panelId = dockPanelId ?? capturedDock.focusedPanelId,
                  app.isCurrentCommandPaletteDockTarget(
                      capturedDock,
                      panelId: panelId,
                      preferredWindow: preferredWindow()
                  ) else {
                return nil
            }
            return capturedDock
        }
        let focusCapturedDock: () -> Bool = {
            guard capturedDock != nil else { return true }
            return focusDock()
        }
        registry.register(commandId: "palette.nextTabInPane") {
            if capturedDock != nil {
                guard let dock = resolvedDock(), focusCapturedDock() else {
                    NSSound.beep()
                    return
                }
                if !dock.performShortcutCommand(.selectNextSurface) {
                    NSSound.beep()
                }
                return
            }
            tabManager.selectNextSurface()
        }
        registry.register(commandId: "palette.previousTabInPane") {
            if capturedDock != nil {
                guard let dock = resolvedDock(), focusCapturedDock() else {
                    NSSound.beep()
                    return
                }
                if !dock.performShortcutCommand(.selectPreviousSurface) {
                    NSSound.beep()
                }
                return
            }
            tabManager.selectPreviousSurface()
        }
        for movement in SurfacePaneMovement.allCases {
            registry.register(commandId: movement.commandID) {
                if capturedDock != nil {
                    guard let dock = resolvedDock(), focusCapturedDock() else {
                        NSSound.beep()
                        return
                    }
                    if !dock.performShortcutCommand(
                        .moveSurfaceToPane(
                            movement,
                            allowMissingDestinationSplit: true
                        )
                    ) {
                        NSSound.beep()
                    }
                    return
                }
                guard let preferredWindow = preferredWindow() else {
                    NSSound.beep()
                    return
                }
                if AppDelegate.shared?.performSurfacePaneMovement(
                    movement,
                    tabManager: tabManager,
                    preferredWindow: preferredWindow
                ) != true {
                    NSSound.beep()
                }
            }
        }
    }
}

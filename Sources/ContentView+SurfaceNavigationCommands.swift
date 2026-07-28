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
                when: { $0.bool(CommandPaletteContextKeys.hasFocusedPanel) },
                enablement: { $0.bool(CommandPaletteContextKeys.panelHasPeerTab) }
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
                when: { $0.bool(CommandPaletteContextKeys.hasFocusedPanel) },
                enablement: { $0.bool(CommandPaletteContextKeys.panelHasPeerTab) }
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
        context: CommandPaletteActionContext
    ) {
        registry.register(commandId: "palette.nextTabInPane") { invocation in
            guard let panelContext = context.panel() else {
                return .targetUnavailable
            }
            let didSelect = tabManager.selectNextSurface(
                tabId: panelContext.workspace.id,
                fromPanelId: panelContext.panelId
            )
            if !didSelect, invocation.source == .commandPalette { NSSound.beep() }
            return didSelect ? .completed : surfaceNavigationFailure(code: "tab_navigation_unavailable")
        }
        registry.register(commandId: "palette.previousTabInPane") { invocation in
            guard let panelContext = context.panel() else {
                return .targetUnavailable
            }
            let didSelect = tabManager.selectPreviousSurface(
                tabId: panelContext.workspace.id,
                fromPanelId: panelContext.panelId
            )
            if !didSelect, invocation.source == .commandPalette { NSSound.beep() }
            return didSelect ? .completed : surfaceNavigationFailure(code: "tab_navigation_unavailable")
        }
        for movement in SurfacePaneMovement.allCases {
            registry.register(commandId: movement.commandID) { invocation in
                guard let panelContext = context.panel() else {
                    return .targetUnavailable
                }
                let didMove = panelContext.workspace.moveSurface(
                    panelId: panelContext.panelId,
                    to: movement
                )
                if !didMove, invocation.source == .commandPalette { NSSound.beep() }
                return didMove ? .completed : surfaceNavigationFailure(code: "surface_navigation_unavailable")
            }
        }
    }

    private func surfaceNavigationFailure(code: String) -> CmuxActionExecutionResult {
        .failed(
            code: code,
            message: String(
                localized: "action.error.configuredActionFailed",
                defaultValue: "The configured action could not be started."
            )
        )
    }
}

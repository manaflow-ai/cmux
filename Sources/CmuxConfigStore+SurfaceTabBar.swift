import Bonsplit
import CmuxFileWatch
import Combine
import CryptoKit
import Foundation


// MARK: - Surface Tab Bar Resolution
extension CmuxConfigStore {
    func resolvedSurfaceTabBarButtons(
        _ buttons: [CmuxSurfaceTabBarButton],
        actions: [String: CmuxResolvedConfigAction],
        settingName: String
    ) -> ResolvedSurfaceTabBarButtons? {
        var resolvedButtons: [CmuxSurfaceTabBarButton] = []
        var terminalCommandSourcePaths: [String: String] = [:]
        resolvedButtons.reserveCapacity(buttons.count)

        for button in buttons {
            do {
                let resolved = try resolvedSurfaceTabBarButton(button, actions: actions)
                resolvedButtons.append(resolved.button)
                guard resolved.button.terminalCommand != nil else { continue }
                if let commandSourcePath = resolved.terminalCommandSourcePath {
                    terminalCommandSourcePaths[resolved.button.id] = commandSourcePath
                }
            } catch {
                NSLog("[CmuxConfig] %@ ignored: %@", settingName, String(describing: error))
                return nil
            }
        }

        return ResolvedSurfaceTabBarButtons(
            buttons: resolvedButtons,
            terminalCommandSourcePaths: terminalCommandSourcePaths
        )
    }

    private func resolvedSurfaceTabBarButton(
        _ button: CmuxSurfaceTabBarButton,
        actions: [String: CmuxResolvedConfigAction]
    ) throws -> ResolvedSurfaceTabBarButtonEntry {
        guard case .actionReference(let identifier) = button.action else {
            return ResolvedSurfaceTabBarButtonEntry(button: button, terminalCommandSourcePath: nil)
        }

        let resolvedIdentifier = canonicalActionID(identifier)
        if let entry = actions[resolvedIdentifier] {
            let resolvedButton = CmuxSurfaceTabBarButton(
                id: button.id,
                title: button.title ?? entry.title,
                icon: button.icon ?? entry.icon,
                tooltip: button.tooltip ?? entry.tooltip ?? entry.title,
                action: entry.action,
                confirm: button.confirm ?? entry.confirm,
                terminalCommandTarget: button.terminalCommandTarget ?? entry.terminalCommandTarget,
                actionSourcePath: entry.actionSourcePath,
                iconSourcePath: button.icon == nil ? entry.iconSourcePath : button.iconSourcePath
            )
            return ResolvedSurfaceTabBarButtonEntry(
                button: resolvedButton,
                terminalCommandSourcePath: resolvedButton.terminalCommand == nil ? nil : entry.actionSourcePath
            )
        }

        if let builtIn = CmuxSurfaceTabBarBuiltInAction(configID: identifier) {
            return ResolvedSurfaceTabBarButtonEntry(
                button: CmuxSurfaceTabBarButton(
                    id: button.id,
                    title: button.title,
                    icon: button.icon,
                    tooltip: button.tooltip,
                    action: .builtIn(builtIn),
                    confirm: button.confirm,
                    terminalCommandTarget: button.terminalCommandTarget
                ),
                terminalCommandSourcePath: nil
            )
        }

        throw DecodingError.dataCorrupted(
            DecodingError.Context(
                codingPath: [],
                debugDescription: "Unknown action reference '\(identifier)'"
            )
        )
    }

    func applySurfaceTabBarButtonsToCurrentManager() {
        tabManager?.applySurfaceTabBarButtons(
            surfaceTabBarButtons,
            sourcePath: surfaceTabBarButtonSourcePath,
            globalConfigPath: globalConfigPath,
            terminalCommandSourcePaths: surfaceTabBarCommandSourcePaths,
            workspaceCommands: surfaceTabBarWorkspaceCommands
        )
    }

    func resolvedSurfaceTabBarWorkspaceCommands(
        _ buttons: [CmuxSurfaceTabBarButton],
        commands: [CmuxCommandDefinition],
        sourcePaths: [String: String]
    ) -> (buttons: [CmuxSurfaceTabBarButton], workspaceCommands: [String: CmuxResolvedCommand]) {
        var visibleButtons: [CmuxSurfaceTabBarButton] = []
        var workspaceCommands: [String: CmuxResolvedCommand] = [:]
        visibleButtons.reserveCapacity(buttons.count)

        for button in buttons {
            guard let commandName = button.workspaceCommandName else {
                visibleButtons.append(button)
                continue
            }

            guard let command = resolvedWorkspaceCommand(
                named: commandName,
                settingName: "surfaceTabBarButtons action",
                commands: commands,
                sourcePaths: sourcePaths
            ) else {
                NSLog(
                    "[CmuxConfig] surfaceTabBarButtons action '%@' hidden because workspace command '%@' is unavailable",
                    button.id,
                    commandName
                )
                continue
            }

            visibleButtons.append(button)
            workspaceCommands[button.id] = command
        }

        return (visibleButtons, workspaceCommands)
    }

}

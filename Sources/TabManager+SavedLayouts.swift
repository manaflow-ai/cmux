import AppKit
import Foundation

extension TabManager {
    @discardableResult
    func openWorkspace(
        fromSavedLayout layout: CmuxSavedLayout,
        cwdOverride: String?,
        templateParameters: [String: String] = [:],
        processEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        baseCwd: String? = nil,
        focus: Bool
    ) throws -> Workspace {
        let resolvedBaseCwd = baseCwd
            ?? FileManager.default.homeDirectoryForCurrentUser.path
        var template = layout.workspace
        if let cwdOverride {
            template.cwd = cwdOverride
        }
        let definition = try template.resolvingTemplateParametersForLaunch(
            templateParameters,
            processEnvironment: processEnvironment
        )
        let resolvedCwd = CmuxConfigStore.resolveCwd(
            definition.cwd,
            relativeTo: resolvedBaseCwd
        )
        let workspace = addWorkspace(
            title: definition.name ?? layout.name,
            workingDirectory: resolvedCwd,
            workspaceEnvironment: definition.env ?? [:],
            inheritWorkingDirectory: false,
            select: focus
        )
        if let color = definition.color {
            workspace.setCustomColor(color)
        }
        if let layoutNode = definition.layout {
            workspace.applyCustomLayout(
                layoutNode,
                baseCwd: resolvedCwd,
                setupCommand: definition.setup
            )
        } else if let setup = definition.setup {
            workspace.sendConfigSetupCommand(setup)
        }
        return workspace
    }

    /// Shared interactive launch path for saved layouts from menus and commands.
    @discardableResult
    func openSavedLayoutInteractively(
        _ layout: CmuxSavedLayout,
        cwdOverride: String?,
        focus: Bool,
        presentingWindow: NSWindow?
    ) -> Bool {
        let processEnvironment = ProcessInfo.processInfo.environment
        return WorkspaceTemplateParameterPrompt(
            processEnvironment: processEnvironment
        ).requestParameters(
            for: layout.workspace,
            displayName: layout.name,
            presentingWindow: presentingWindow
        ) { parameters in
            guard let parameters else { return }
            do {
                _ = try self.openWorkspace(
                    fromSavedLayout: layout,
                    cwdOverride: cwdOverride,
                    templateParameters: parameters,
                    processEnvironment: processEnvironment,
                    focus: focus
                )
            } catch {
                WorkspaceTemplateErrorPresenter(
                    presentingWindow: presentingWindow
                ).present(error)
            }
        }
    }
}

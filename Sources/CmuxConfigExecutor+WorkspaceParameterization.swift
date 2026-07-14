import AppKit
import CmuxFoundation
import Foundation

extension CmuxConfigExecutor {
    static func resolvedWorkspaceCommandForLaunch(
        _ command: CmuxCommandDefinition,
        presentingWindow: NSWindow?
    ) -> CmuxCommandDefinition? {
        guard let workspace = command.workspace else { return command }
        do {
            var resolved = command
            resolved.workspace = try workspace.resolvingTemplateParameters(
                [:],
                processEnvironment: ProcessInfo.processInfo.environment
            )
            return resolved
        } catch CmuxTemplateResolutionError.missingVariables(let names) {
            WorkspaceTemplateErrorPresenter(presentingWindow: presentingWindow).present(
                CmuxTemplateResolutionError.missingVariables(names)
            )
            return nil
        } catch {
            WorkspaceTemplateErrorPresenter(presentingWindow: presentingWindow).present(error)
            return nil
        }
    }
}

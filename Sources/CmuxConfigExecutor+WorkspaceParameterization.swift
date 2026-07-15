import AppKit
import CmuxFoundation
import Foundation

extension CmuxConfigExecutor {
    static func resolvedWorkspaceCommandForLaunch(
        _ command: CmuxCommandDefinition,
        templateParameters: [String: String] = [:],
        processEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> CmuxCommandDefinition {
        guard let workspace = command.workspace else { return command }
        var resolved = command
        resolved.workspace = try workspace.resolvingTemplateParametersForLaunch(
            templateParameters,
            processEnvironment: processEnvironment
        )
        return resolved
    }
}

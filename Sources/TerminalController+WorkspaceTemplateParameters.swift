import CmuxFoundation
import Foundation

extension TerminalController {
    func workspaceTemplateResolutionFailure(_ error: Error) -> V2CallResult {
        if case CmuxTemplateResolutionError.missingVariables(let names) = error {
            return .err(
                code: "missing_parameters",
                message: "Missing workspace template parameters: \(names.joined(separator: ", "))",
                data: ["missing_parameters": names]
            )
        }
        return .err(
            code: "invalid_params",
            message: "Workspace template parameters could not be resolved",
            data: nil
        )
    }
}

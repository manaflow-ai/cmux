import Foundation

extension TerminalController {
    enum WorkspaceCreateWorkingDirectoryValidation: Equatable, Sendable {
        case notProvided
        case valid(String)
        case invalid
        case cancelled
    }

    typealias WorkspaceCreateWorkingDirectoryValidator = @Sendable (
        _ rawValue: String?,
        _ isProvided: Bool
    ) async -> WorkspaceCreateWorkingDirectoryValidation

    nonisolated static var v2InvalidWorkingDirectoryResult: V2CallResult {
        .err(
            code: "invalid_params",
            message: "working_directory must be an absolute existing directory",
            data: ["field": "working_directory"]
        )
    }

    private nonisolated static func v2ValidateWorkingDirectory(
        rawValue: String?,
        isProvided: Bool
    ) -> WorkspaceCreateWorkingDirectoryValidation {
        guard isProvided else { return .notProvided }
        guard let workingDirectory = v2ExpandedWorkingDirectory(rawValue),
              (workingDirectory as NSString).isAbsolutePath else {
            return .invalid
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: workingDirectory, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return .invalid
        }
        return .valid(workingDirectory)
    }

    nonisolated static func v2ValidateMobileWorkingDirectory(
        rawValue: String?,
        isProvided: Bool
    ) async -> WorkspaceCreateWorkingDirectoryValidation {
        guard !Task.isCancelled else { return .cancelled }
        let validation = await Task.detached(priority: .utility) {
            guard !Task.isCancelled else { return WorkspaceCreateWorkingDirectoryValidation.cancelled }
            return v2ValidateWorkingDirectory(rawValue: rawValue, isProvided: isProvided)
        }.value
        guard !Task.isCancelled else { return .cancelled }
        return validation
    }
}

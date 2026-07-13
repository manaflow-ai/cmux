import Darwin
import Foundation

extension TerminalController {
    enum WorkspaceCreateWorkingDirectoryValidation: Equatable, Sendable {
        case notProvided
        case valid(String)
        case invalid
        case timedOut
        case cancelled
    }

    typealias WorkspaceCreateWorkingDirectoryValidator = @Sendable (
        _ rawValue: String?,
        _ isProvided: Bool
    ) async -> WorkspaceCreateWorkingDirectoryValidation

    nonisolated static let v2MobileWorkingDirectoryValidationService =
        WorkspaceCreateWorkingDirectoryValidationService(
            timeout: .seconds(3),
            localCapacity: 1,
            externalCapacity: 2,
            laneClassifier: v2WorkingDirectoryProbeLane,
            probe: { path in
                await Task.detached(priority: .utility) {
                    var isDirectory: ObjCBool = false
                    return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
                        && isDirectory.boolValue
                }.value
            },
            sleepUntilDeadline: { timeout in
                try? await ContinuousClock().sleep(for: timeout)
            }
        )

    nonisolated static func v2WorkingDirectoryProbeLane(
        _ path: String
    ) -> WorkspaceCreateWorkingDirectoryValidationService.ProbeLane {
        var mounts: UnsafeMutablePointer<statfs>?
        let mountCount = getmntinfo(&mounts, MNT_NOWAIT)
        guard mountCount > 0, let mounts else { return .external }
        let normalizedPath = (path as NSString).standardizingPath
        var longestMatchLength = -1
        var longestMatchIsLocal = false
        for index in 0..<Int(mountCount) {
            let fileSystem = mounts[index]
            let mountPath = withUnsafePointer(to: fileSystem.f_mntonname) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: 1) {
                    String(cString: $0)
                }
            }
            let matches = normalizedPath == mountPath
                || normalizedPath.hasPrefix(mountPath == "/" ? "/" : "\(mountPath)/")
            guard matches, mountPath.count > longestMatchLength else { continue }
            longestMatchLength = mountPath.count
            longestMatchIsLocal = (fileSystem.f_flags & UInt32(MNT_LOCAL)) != 0
        }
        return longestMatchIsLocal ? .local : .external
    }

    nonisolated static var v2InvalidWorkingDirectoryResult: V2CallResult {
        .err(
            code: "invalid_working_directory",
            message: "working_directory must be an absolute existing directory",
            data: ["field": "working_directory"]
        )
    }

    nonisolated static func v2ValidateMobileWorkingDirectory(
        rawValue: String?,
        isProvided: Bool
    ) async -> WorkspaceCreateWorkingDirectoryValidation {
        guard !Task.isCancelled else { return .cancelled }
        let validation = await v2MobileWorkingDirectoryValidationService.validate(
            rawValue: rawValue,
            isProvided: isProvided
        )
        guard !Task.isCancelled else { return .cancelled }
        return validation
    }
}

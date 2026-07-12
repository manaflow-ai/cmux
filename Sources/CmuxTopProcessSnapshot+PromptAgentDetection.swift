import Foundation

extension CmuxTopProcessSnapshot {
    /// Verifies one foreground PID without enumerating the process table.
    nonisolated static func promptAgentDefinition(
        foregroundPID: Int
    ) -> CmuxTaskManagerCodingAgentDefinition? {
        guard let details = processArgumentsAndEnvironment(for: foregroundPID),
              let executable = details.arguments.first else {
            return nil
        }
        let definition = CmuxTaskManagerCodingAgentDefinition.matchingDefinition(
            processName: (executable as NSString).lastPathComponent,
            processPath: executable,
            arguments: details.arguments,
            environment: details.environment
        )
        guard definition?.promptTurnDetection != nil else {
            return nil
        }
        return definition
    }
}

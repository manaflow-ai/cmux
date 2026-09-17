import CMUXAgentLaunch
import Foundation

extension CMUXCLI {
    func controlAgentLaunchCommandPayload(
        _ command: AgentLaunchCommand
    ) -> [String: Any] {
        var payload: [String: Any] = ["arguments": command.arguments]
        if let launcher = command.launcher {
            payload["launcher"] = launcher
        }
        if let executablePath = command.executablePath {
            payload["executable_path"] = executablePath
        }
        if let workingDirectory = command.workingDirectory {
            payload["working_directory"] = workingDirectory
        }
        if let environment = command.environment {
            payload["environment"] = environment
        }
        if let verificationHome = command.verificationHome {
            payload["verification_home"] = verificationHome
        }
        if let capturedAt = command.capturedAt {
            payload["captured_at"] = capturedAt
        }
        if let source = command.source {
            payload["source"] = source
        }
        return payload
    }
}

import CMUXAgentLaunch
import Foundation

extension AgentLaunchCommandSnapshot {
    init(
        processDetectedLauncher launcher: String,
        executablePath: String?,
        arguments: [String],
        workingDirectory: String?,
        environment: [String: String]
    ) {
        var selectedEnvironment = AgentLaunchEnvironmentPolicy.selectedEnvironment(from: environment, kind: launcher)
        if launcher == "opencode",
           let path = environment["PATH"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !path.isEmpty {
            selectedEnvironment["PATH"] = path
        }
        self.init(
            launcher: launcher,
            executablePath: executablePath,
            arguments: arguments,
            workingDirectory: workingDirectory,
            environment: selectedEnvironment.isEmpty ? nil : selectedEnvironment,
            capturedAt: nil,
            source: "process"
        )
    }
}

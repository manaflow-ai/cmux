import Foundation

struct AgentSessionLaunchPlan: Equatable, Sendable {
    let provider: AgentSessionProviderID
    let executableURL: URL
    let arguments: [String]
    let environment: [String: String]

    func environment(overridingWorkingDirectory workingDirectory: String?) -> [String: String] {
        var launchEnvironment = environment
        guard let workingDirectory = workingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines),
              !workingDirectory.isEmpty else {
            return launchEnvironment
        }

        launchEnvironment["PWD"] = URL(fileURLWithPath: workingDirectory, isDirectory: true)
            .standardizedFileURL
            .path
        return launchEnvironment
    }

}


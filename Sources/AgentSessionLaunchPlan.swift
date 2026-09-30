import Foundation

struct AgentSessionLaunchPlan: Equatable, Sendable {
    let provider: AgentSessionProviderID
    let executableURL: URL
    let arguments: [String]
    let environment: [String: String]

    func environment(overridingWorkingDirectory workingDirectory: String?) -> [String: String] {
        var launchEnvironment = environment
        if provider == .opencode,
           launchEnvironment["OPENCODE_SERVER_PASSWORD"]?.isEmpty != false {
            launchEnvironment["OPENCODE_SERVER_USERNAME"] = launchEnvironment["OPENCODE_SERVER_USERNAME"].flatMap { value in
                value.isEmpty ? nil : value
            } ?? "opencode"
            launchEnvironment["OPENCODE_SERVER_PASSWORD"] = "\(UUID().uuidString)-\(UUID().uuidString)"
        }
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

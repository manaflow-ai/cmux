import Foundation
import CmuxSettings

enum AgentSessionScratchDirectory {
    private static let rootName = "agent-artifacts"

    static func prepare(
        sessionID: String,
        provider: AgentSessionProviderID,
        fileManager: FileManager = .default
    ) throws -> URL {
        let root = CmuxStateDirectory.url(homeDirectory: fileManager.homeDirectoryForCurrentUser)
            .appendingPathComponent(rootName, isDirectory: true)
            .appendingPathComponent(provider.rawValue, isDirectory: true)
            .appendingPathComponent(sessionID, isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let manifest = root.appendingPathComponent(".cmux-owned", isDirectory: false)
        if !fileManager.fileExists(atPath: manifest.path) {
            try Data("cmux-agent-artifact-v1\n".utf8).write(to: manifest, options: .atomic)
        }
        return root
    }
}

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

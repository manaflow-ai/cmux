import Foundation
import CMUXAgentContinuation

public enum ClaudeConfigDirectoryPath {
    public static func preferredPath(
        _ rawPath: String,
        fileManager: FileManager = .default,
        homeDirectory: String = NSHomeDirectory()
    ) -> String {
        CMUXAgentContinuation.ClaudeConfigDirectoryPath.preferredPath(
            rawPath,
            fileManager: fileManager,
            homeDirectory: homeDirectory
        )
    }
}

public enum AgentLaunchEnvironmentPolicy {
    public static func selectedEnvironment(from env: [String: String], kind: String? = nil) -> [String: String] {
        AgentContinuationEnvironmentPolicy.selectedEnvironment(from: env, kind: kind)
    }

    public static func sanitizedValue(key: String, value: String?) -> String? {
        AgentContinuationEnvironmentPolicy.sanitizedValue(key: key, value: value)
    }
}

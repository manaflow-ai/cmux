import Foundation

public nonisolated enum WorkstreamAgentSpawnTool {
    public static func isSpawnToolName(_ toolName: String) -> Bool {
        let normalized = toolName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized == "task" || normalized == "agent"
    }
}

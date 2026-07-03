import Foundation

struct ClaudeSessionRoot: Hashable {
    let configDir: String
    let resumeConfigDirectory: String?

    var projectsRoot: String {
        (configDir as NSString).appendingPathComponent("projects")
    }
}

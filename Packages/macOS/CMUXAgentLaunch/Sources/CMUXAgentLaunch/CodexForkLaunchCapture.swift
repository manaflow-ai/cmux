import Foundation

struct CodexForkLaunchCapture {
    let args: [String]
    let forkIndex: Int
    let sessionIndex: Int
    let preserveOptions: ([String], AgentLaunchSanitizer.Policy) -> [String]?

    func arguments() -> [String]? {
        let prefix = Array(args[..<forkIndex])
        guard let preservedPrefix = preserveOptions(prefix, AgentLaunchSanitizer.codexPolicy) else {
            return nil
        }

        let sourceSessionId = args[sessionIndex]
        var postFork: [String] = []
        var index = forkIndex + 1
        while index < args.count {
            if index != sessionIndex {
                postFork.append(args[index])
            }
            index += 1
        }

        var replayPolicy = AgentLaunchSanitizer.codexPolicy
        replayPolicy.nonRestorableCommands = []
        replayPolicy.preservePositionals = true
        guard let preservedReplayTail = preserveOptions(postFork, replayPolicy) else { return nil }

        return preservedPrefix + ["fork", sourceSessionId] + preservedReplayTail
    }
}

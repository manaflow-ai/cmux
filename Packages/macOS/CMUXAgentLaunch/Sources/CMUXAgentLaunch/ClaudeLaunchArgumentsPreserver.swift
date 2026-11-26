import Foundation

struct ClaudeLaunchArgumentsPreserver {
    private let preserveOptions: ([String], AgentLaunchSanitizer.Policy) -> [String]?

    init(
        preserveOptions: @escaping ([String], AgentLaunchSanitizer.Policy) -> [String]? = AgentLaunchSanitizer.preserveOptions
    ) {
        self.preserveOptions = preserveOptions
    }

    func preservedArguments(
        args: [String],
        stripCmuxHookSettings: Bool = true
    ) -> [String]? {
        var policy = AgentLaunchSanitizer.claudePolicy
        policy.skipClaudeHookSettings = stripCmuxHookSettings
        return preserveOptions(args, policy)
    }
}

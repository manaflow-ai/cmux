import Foundation

extension AgentLaunchSanitizer {
    static let claudeTeamsPolicy: Policy = {
        var policy = claudePolicy
        policy.valueOptions.subtract(["--tmux", "--worktree", "-w"])
        policy.optionalValueOptions.formUnion([
            "--prompt-suggestions",
            "--remote-control",
            "--worktree",
            "-w"
        ])
        policy.optionalValueChoices["--prompt-suggestions"] = ["true", "false"]
        policy.greedyOptionalValueOptions.formUnion(["--remote-control", "--worktree", "-w"])
        policy.droppedOptions.subtract(["--tmux", "--worktree", "-w"])
        policy.droppedOptionPrefixes.removeAll { $0 == "--tmux=" || $0 == "--worktree=" }
        policy.promptBoundaryOptions = ["--tmux"]
        return policy
    }()
}

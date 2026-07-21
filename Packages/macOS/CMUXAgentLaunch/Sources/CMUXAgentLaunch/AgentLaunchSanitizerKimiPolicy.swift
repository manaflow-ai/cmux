import Foundation

extension AgentLaunchSanitizer {
    /// Preserves interactive Kimi configuration without replaying a prior session selector or one-shot mode.
    static let kimiPolicy = Policy(
        valueOptions: [
            "--work-dir", "-w",
            "--add-dir",
            "--session", "--resume", "-S", "-r",
            "--config", "--config-file",
            "--model", "-m",
            "--prompt", "--command", "-p", "-c",
            "--input-format", "--output-format",
            "--agent", "--agent-file",
            "--mcp-config-file", "--mcp-config", "--skills-dir",
            "--max-steps-per-turn", "--max-retries-per-step", "--max-ralph-iterations",
        ],
        optionalValueOptions: [
            "--session", "--resume", "-S", "-r",
        ],
        booleanOptions: [
            "--verbose", "--debug",
            "--continue", "-C",
            "--thinking", "--no-thinking",
            "--yolo", "--yes", "--auto-approve", "-y",
            "--plan", "--afk",
            "--print", "--acp", "--wire",
            "--final-message-only", "--quiet",
        ],
        nonRestorableCommands: [
            "login", "logout", "term", "acp", "info", "export", "mcp", "plugin", "vis", "web",
        ],
        droppedOptions: [
            "--session", "--resume", "-S", "-r",
            "--continue", "-C",
            "--prompt", "--command", "-p", "-c",
            "--yolo", "--yes", "--auto-approve", "-y", "--afk",
            "--config", "--mcp-config",
            "--output-format", "--final-message-only",
        ],
        droppedOptionPrefixes: [
            "--session=", "--resume=", "-S=", "-r=",
            "--prompt=", "--command=", "-p=", "-c=",
            "--config=", "--mcp-config=",
            "--output-format=",
        ],
        rejectOptions: [
            "--print", "--acp", "--wire",
            "--input-format", "--quiet",
        ]
    )
}

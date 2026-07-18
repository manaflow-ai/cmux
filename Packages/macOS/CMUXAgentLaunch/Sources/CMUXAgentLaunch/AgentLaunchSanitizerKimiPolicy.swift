import Foundation

extension AgentLaunchSanitizer {
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
            "--auto-approve",
            "--debug",
            "--no-thinking",
            "--plan",
            "--thinking",
            "--verbose",
            "--yolo",
            "--yes",
            "-y",
        ],
        variadicOptions: [
            "--add-dir", "--mcp-config-file", "--mcp-config", "--skills-dir",
        ],
        nonRestorableCommands: [
            "login", "logout", "term", "acp", "info", "export", "mcp", "plugin", "vis", "web",
        ],
        droppedOptions: [
            "--session", "--resume", "-S", "-r",
            "--continue", "-C",
            "--prompt", "--command", "-p", "-c",
            "--config", "--mcp-config",
            "--acp", "--wire",
            "--input-format", "--output-format", "--final-message-only",
        ],
        droppedOptionPrefixes: [
            "--session=", "--resume=", "-S=", "-r=",
            "--prompt=", "--command=", "-p=", "-c=",
            "--config=", "--mcp-config=",
            "--input-format=", "--output-format=",
        ],
        rejectOptions: [
            "--print", "--quiet",
        ]
    )
}

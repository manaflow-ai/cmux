import Foundation

extension AgentLaunchSanitizer {
    static let grokPolicy = Policy(
        valueOptions: [
            "--agent",
            "--agents",
            "--allow",
            "--cwd",
            "--deny",
            "--disallowed-tools",
            "--effort",
            "--max-turns",
            "--model",
            "-m",
            "--permission-mode",
            "--reasoning-effort",
            "--resume",
            "-r",
            "--rules",
            "--sandbox",
            "--session-id",
            "--system-prompt-override",
            "--tools",
            "--worktree",
            "-w"
        ],
        optionalValueOptions: [
            "--resume",
            "-r",
            "--worktree",
            "-w"
        ],
        nonRestorableCommands: [
            "agent",
            "help",
            "import",
            "inspect",
            "leader",
            "login",
            "mcp",
            "memory",
            "models",
            "sessions",
            "setup",
            "share",
            "ssh",
            "trace",
            "update",
            "version",
            "v",
            "worktree"
        ],
        droppedOptions: [
            "--continue",
            "-c",
            "--restore-code",
            "--resume",
            "-r",
            "--fork-session",
            "--session-id",
            "--worktree",
            "-w"
        ],
        droppedOptionPrefixes: [
            "--resume=",
            "-r=",
            "--fork-session=",
            "--session-id=",
            "--worktree=",
            "-w="
        ],
        rejectOptions: [
            "--best-of-n",
            "--output-format",
            "--prompt-file",
            "--prompt-json",
            "--single",
            "-p"
        ]
    )
}

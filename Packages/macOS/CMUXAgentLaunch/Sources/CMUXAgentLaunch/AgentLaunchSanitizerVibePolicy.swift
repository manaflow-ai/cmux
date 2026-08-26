import Foundation

extension AgentLaunchSanitizer {
    /// Preserves interactive Vibe configuration without replaying a prior session selector or one-shot mode.
    static let vibePolicy = Policy(
        valueOptions: [
            "--workdir",
            "--add-dir",
            "--agent",
            "--resume",
            "--prompt", "-p",
            "--max-turns",
            "--max-price",
            "--max-tokens",
            "--output",
            "--worktree",
        ],
        optionalValueOptions: [
            "--resume",
            "--prompt", "-p",
            "--worktree",
        ],
        booleanOptions: [
            "--auto-approve", "--yolo",
            "--trust",
            "--continue", "-c",
            "--setup", "--check-upgrade",
            "-v", "--version",
            "-h", "--help",
        ],
        variadicOptions: [
            "--enabled-tools",
            "--disabled-tools",
        ],
        nonRestorableCommands: [],
        droppedOptions: [
            "--resume", "-c", "--continue",
            "--prompt", "-p",
            "--max-turns", "--max-price", "--max-tokens",
            "--output",
        ],
        droppedOptionPrefixes: [
            "--resume=",
            "--prompt=", "-p=",
            "--max-turns=", "--max-price=", "--max-tokens=",
            "--output=",
        ],
        rejectOptions: [
            "--setup", "--check-upgrade",
            "-v", "--version", "-h", "--help",
        ]
    )
}

import Foundation

extension AgentLaunchSanitizer {
    /// Preserves interactive Muse Code options without replaying a prior session
    /// selector, a one-shot prompt, or a fresh worktree request.
    ///
    /// Root options may appear on either side of `muse resume`, so the resume
    /// subcommand and its session reference are skipped and options after it kept.
    static let musePolicy = Policy(
        valueOptions: [
            "--agents",
            "--provider",
            "--preset",
            "--model",
            "--contributor-mode",
            "--config", "-c",
            "--reasoning-effort", "--effort",
            "--base-url",
            "--image",
            "--workspace",
            "--worktree-base",
            "--worktree-existing",
            "--approval-mode",
            "--permission-profile",
            "--approval-judge",
            "--echo-delay-ms",
            "--sandbox-network",
        ],
        optionalValueOptions: ["--worktree", "-w"],
        optionalValueChoices: [
            "--worktree": ["off", "create", "existing"],
            "-w": ["off", "create", "existing"],
        ],
        booleanOptions: [
            "--last",
            "--parallel-tool-calls", "--no-parallel-tool-calls",
            "--subagent-worktree-isolation",
            "--yolo",
            "--trust-workspace",
            "--disable-approval",
            "--disable-sandbox",
            "--disable-write",
            "--disable-shell",
            "--enable-shell-tool",
        ],
        nonRestorableCommands: [
            "exec", "config", "export", "trace", "model-profile", "skills", "voice",
            "plugins", "sandbox", "schema", "serve", "session-message", "mcp",
            "auth", "login", "logout", "init", "help",
        ],
        droppedOptions: [
            "--last",
            "--image",
            "--worktree", "-w",
            "--worktree-base",
            "--worktree-existing",
        ],
        droppedOptionPrefixes: [
            "--image=",
            "--worktree=", "-w=",
            "--worktree-base=",
            "--worktree-existing=",
        ],
        rejectOptions: [
            "--no-session-log",
            "--help", "-h",
            "--version", "-V",
        ],
        resumeSubcommand: "resume"
    )
}

import CMUXAgentLaunch
import Testing

/// A Claude permission mode selected in-session (shift+tab auto-accept, plan mode,
/// bypass toggle) is runtime state, not argv, so replay-based restore can never
/// recover it from the captured launch command. cmux observes the live mode from
/// hook payloads; the resume/fork argv builders re-apply it as `--permission-mode`
/// on user-owned restore. Explicit launch flags always win over observed state,
/// and the claude-teams launcher path never gains observed state (an orphaned
/// teammate respawn is not a fresh permission opt-in).
/// https://github.com/manaflow-ai/cmux/issues/8066
@Suite("Claude permission mode restore")
struct ClaudePermissionModeRestoreTests {
    @Test("Resume argv appends observed non-default permission mode")
    func resumeArgvAppendsObservedMode() {
        #expect(
            AgentResumeArgv().builtInKind(
                kind: "claude",
                sessionId: "SID",
                executablePath: nil,
                arguments: ["claude"],
                observedPermissionMode: "acceptEdits"
            ) == ["claude", "--resume", "SID", "--permission-mode", "acceptEdits"]
        )
        #expect(
            AgentResumeArgv().builtInKind(
                kind: "claude",
                sessionId: "SID",
                executablePath: nil,
                arguments: ["claude", "--model", "opus"],
                observedPermissionMode: "plan"
            ) == ["claude", "--resume", "SID", "--model", "opus", "--permission-mode", "plan"]
        )
        #expect(
            AgentResumeArgv().builtInKind(
                kind: "claude",
                sessionId: "SID",
                executablePath: nil,
                arguments: ["claude"],
                observedPermissionMode: "bypassPermissions"
            ) == ["claude", "--resume", "SID", "--permission-mode", "bypassPermissions"]
        )
    }

    @Test("Default, empty, and unrecognized observed modes are not emitted")
    func defaultEmptyAndUnrecognizedModesAreNotEmitted() {
        let plain = ["claude", "--resume", "SID"]
        for mode in ["default", "  ", "yolo; rm -rf /", ""] {
            #expect(
                AgentResumeArgv().builtInKind(
                    kind: "claude",
                    sessionId: "SID",
                    executablePath: nil,
                    arguments: ["claude"],
                    observedPermissionMode: mode
                ) == plain
            )
        }
        #expect(
            AgentResumeArgv().builtInKind(
                kind: "claude",
                sessionId: "SID",
                executablePath: nil,
                arguments: ["claude"],
                observedPermissionMode: nil
            ) == plain
        )
    }

    @Test("Explicit --permission-mode launch flag wins over observed state")
    func explicitPermissionModeFlagWins() {
        #expect(
            AgentResumeArgv().builtInKind(
                kind: "claude",
                sessionId: "SID",
                executablePath: nil,
                arguments: ["claude", "--permission-mode", "plan"],
                observedPermissionMode: "acceptEdits"
            ) == ["claude", "--resume", "SID", "--permission-mode", "plan"]
        )
        #expect(
            AgentResumeArgv().builtInKind(
                kind: "claude",
                sessionId: "SID",
                executablePath: nil,
                arguments: ["claude", "--permission-mode=plan"],
                observedPermissionMode: "acceptEdits"
            ) == ["claude", "--resume", "SID", "--permission-mode=plan"]
        )
    }

    @Test("Explicit bypass launch flag wins over observed state")
    func explicitBypassFlagWins() {
        #expect(
            AgentResumeArgv().builtInKind(
                kind: "claude",
                sessionId: "SID",
                executablePath: nil,
                arguments: ["claude", "--dangerously-skip-permissions"],
                observedPermissionMode: "plan"
            ) == ["claude", "--resume", "SID", "--dangerously-skip-permissions"]
        )
    }

    @Test("Flag-shaped token inside a value slot is not an explicit permission flag")
    func flagShapedValueSlotTokenIsNotExplicit() {
        #expect(
            AgentResumeArgv().builtInKind(
                kind: "claude",
                sessionId: "SID",
                executablePath: nil,
                arguments: ["claude", "--append-system-prompt", "--permission-mode"],
                observedPermissionMode: "plan"
            ) == [
                "claude",
                "--resume",
                "SID",
                "--append-system-prompt",
                "--permission-mode",
                "--permission-mode",
                "plan"
            ]
        )
    }

    @Test("Fork argv appends observed non-default permission mode")
    func forkArgvAppendsObservedMode() {
        #expect(
            AgentForkArgv().builtInKind(
                kind: "claude",
                sessionId: "SID",
                executablePath: nil,
                arguments: ["claude"],
                observedPermissionMode: "acceptEdits"
            ) == ["claude", "--resume", "SID", "--fork-session", "--permission-mode", "acceptEdits"]
        )
        #expect(
            AgentForkArgv().builtInKind(
                kind: "claude",
                sessionId: "SID",
                executablePath: nil,
                arguments: ["claude", "--dangerously-skip-permissions"],
                observedPermissionMode: "plan"
            ) == ["claude", "--resume", "SID", "--fork-session", "--dangerously-skip-permissions"]
        )
    }

    @Test("Non-claude kinds ignore observed permission mode")
    func nonClaudeKindsIgnoreObservedMode() {
        #expect(
            AgentResumeArgv().builtInKind(
                kind: "codex",
                sessionId: "SID",
                executablePath: nil,
                arguments: ["codex"],
                observedPermissionMode: "plan"
            ) == ["codex", "resume", "SID", "-c", "check_for_update_on_startup=false"]
        )
    }

    @Test("Teams orphan respawn path never gains observed permission state")
    func teamsLauncherResolutionNeverGainsObservedMode() {
        // launcherResolution deliberately has no observed-mode input: an orphaned
        // teammate pane restored after the parent session is gone must fall back
        // to Claude's own trust/permission prompts, exactly as before.
        #expect(
            AgentResumeArgv().launcherResolution(
                launcher: "claudeTeams",
                sessionId: "SID",
                executablePath: nil,
                arguments: ["cmux", "claude-teams", "--model", "sonnet"]
            ) == .resolved(["cmux", "claude-teams", "--resume", "SID", "--model", "sonnet"])
        )
    }
}

import CMUXAgentLaunch
import Testing

/// The hibernation lifecycle correctness for every coding-agent kind funnels through
/// one shared decision: `AgentNotification.isBlockingPrompt`. Both the
/// dedicated Claude hook lane and the generic agent-hook lane (codex, grok, gemini,
/// opencode, cursor, kiro, antigravity, rovodev, copilot, codebuddy, factory, qoder,
/// hermes-agent, pi, amp, and custom vault agents) use it to decide whether a
/// Notification may flip the lifecycle to `.needsInput`. A routine "waiting for input"
/// reminder must NOT be blocking, or it clobbers the Stop hook's `.idle` and the pane
/// never hibernates (the "only codex hibernates" class of bug). This suite pins that
/// contract.
@Suite("AgentNotification")
struct AgentNotificationBlockingClassifierTests {
    @Test("Permission/approval prompts and errors are blocking")
    func genuinelyBlockingNotificationsAreBlocking() {
        // The only notifications a user must act on; they keep the pane live across
        // every agent kind.
        let blocking = [
            "permission",
            "approve",
            "approval",
            "permission_prompt",
            "Claude needs your permission to use Bash",
            "Approval needed",
            "Codex requested approval to run a command",
            "error",
            "failed",
            "failure",
            "exception",
            "grok reported an error",
            "command failed with exit code 1",
            "uncaught exception in tool call",
        ]
        for message in blocking {
            #expect(
                AgentNotification(signal: "", message: message).isBlockingPrompt,
                "Expected blocking for message \(message.debugDescription)"
            )
        }
    }

    @Test("Waiting/completion/attention reminders are not blocking")
    func routineNotificationsAreNotBlocking() {
        // Routine waiting/idle reminders, completions, and generic attention must NOT
        // be blocking: they leave the Stop hook's `.idle` intact so the agent hibernates.
        let nonBlocking = [
            "Claude is waiting for your input",
            "waiting for input",
            "Claude is waiting for your response",
            "Turn complete in 1.0s.",
            "Task completed",
            "done",
            "Claude needs your input",
            "needs your attention",
            "Please confirm to continue",
            "ready",
            "idle",
            "",
        ]
        for message in nonBlocking {
            #expect(
                !AgentNotification(signal: "", message: message).isBlockingPrompt,
                "Expected NOT blocking for message \(message.debugDescription)"
            )
        }
    }

    @Test("The structured signal field also drives the blocking decision")
    func signalFieldAlsoDrivesBlocking() {
        // A `reason: permission_prompt` with an empty message is still blocking.
        #expect(AgentNotification(signal: "permission_prompt", message: "").isBlockingPrompt)
        #expect(AgentNotification(signal: "error", message: "something happened").isBlockingPrompt)
        #expect(!AgentNotification(signal: "notification", message: "waiting").isBlockingPrompt)
    }
}

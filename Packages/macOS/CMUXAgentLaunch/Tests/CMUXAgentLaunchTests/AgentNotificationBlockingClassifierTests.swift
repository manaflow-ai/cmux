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

    @Test("Genuine prompts are blocking")
    func genuinePromptsAreBlocking() {
        // An agent whose only needs-input signal is a Notification hook must keep its
        // pane live while the user answers. Blocking is keyed on high-confidence signals:
        // a direct interrogative (`?`), or the `question` token paired with an interaction
        // word. Note real y/n prompts carry a `?` ("Overwrite? (y/n)"), so `?` covers them.
        let blocking = [
            "Proceed with changes?",
            "Which option do you want? Type 1 or 2.",
            "Overwrite the file? (y/n)",
            "Apply this migration? [y/N]",
            "Claude has a question for you, please answer",
            "Question: which approach do you want?",
            "The agent has a question — reply to continue",
            // Completion wording must not defuse a live question: the CLI classifier
            // orders completion cues before waiting cues, so blocking here is what keeps
            // "done + question" text from durably writing `.idle` mid-prompt.
            "Task completed. Continue?",
            "Build finished — deploy to staging?",
        ]
        for message in blocking {
            #expect(
                AgentNotification(signal: "", message: message).isBlockingPrompt,
                "Expected blocking for genuine prompt \(message.debugDescription)"
            )
        }
        // The structured signal field carries the cue too.
        #expect(AgentNotification(signal: "question", message: "reply to continue").isBlockingPrompt)
    }

    @Test("Routine reminders without an interrogative stay non-blocking")
    func routineRemindersStayNonBlocking() {
        // Regression guard for the primary fix: a routine idle/waiting reminder must NOT
        // be blocking even though it mentions input/response/continue, or it clobbers the
        // Stop hook's `.idle` and the pane never hibernates. None carry a `?` or the
        // `question` token.
        let nonBlocking = [
            "Claude is waiting for your input",
            "Claude is waiting for your response",
            "waiting for input",
            "idle prompt",
            "needs your input",
            "continue when ready",
            "proceed to the next step",
            // Punctuation-free imperatives are INTENTIONALLY non-blocking here: keying on
            // bare "confirm"/"choose" verbs collides with routine chatter and re-breaks
            // hibernation. These are left to the authoritative structured signal.
            "Please confirm to continue",
            "Choose an option",
        ]
        for message in nonBlocking {
            #expect(
                !AgentNotification(signal: "", message: message).isBlockingPrompt,
                "Expected NOT blocking for routine reminder \(message.debugDescription)"
            )
        }
    }
}

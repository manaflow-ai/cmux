import CMUXAgentLaunch
import Testing

/// The Claude Stop hook fires when a turn ends, and cmux records the pane `.idle`
/// there — which makes it hibernation-eligible. But Claude may have launched
/// `run_in_background` Bash tasks or a Monitor that outlives the turn: a silent
/// background task (its own process group, no terminal output) is invisible to the
/// scrollback+PID activity fingerprint, so the pane hibernates and the group SIGTERM
/// kills the live work. Claude Code hands the Stop hook a structured `background_tasks`
/// array (and `session_crons`); a task with a non-terminal status means work is still
/// running. This suite pins the detection that keeps such a pane out of hibernation.
@Suite("AgentBackgroundWork")
struct AgentBackgroundWorkStatusTests {
    // The exact shape observed empirically from a Claude Code 2.1.197 Stop hook while a
    // `sleep 20 && echo BGDONE` background shell was still alive.
    private func runningTask(status: String = "running") -> [String: Any] {
        [
            "id": "bnlimlndi",
            "type": "shell",
            "status": status,
            "description": "Background sleep and echo command",
            "command": "sleep 20 && echo BGDONE",
        ]
    }

    @Test("A running background task keeps the pane active")
    func runningBackgroundTaskIsActive() {
        let status = AgentBackgroundWorkStatus(hookObject: [
            "hook_event_name": "Stop",
            "background_tasks": [runningTask()],
            "session_crons": [],
        ])
        #expect(status.isActive)
        #expect(status.runningBackgroundTaskCount == 1)
    }

    @Test("An empty payload is inactive (turn is genuinely idle)")
    func emptyPayloadIsInactive() {
        // Control: no background work. Claude drops finished tasks from the array, so
        // both arrays empty cleanly means nothing is pending and the pane may hibernate.
        let status = AgentBackgroundWorkStatus(hookObject: [
            "hook_event_name": "Stop",
            "background_tasks": [],
            "session_crons": [],
        ])
        #expect(!status.isActive)
        #expect(status.runningBackgroundTaskCount == 0)
        #expect(status.scheduledCronCount == 0)
    }

    @Test("A scheduled session cron keeps the pane active")
    func scheduledCronIsActive() {
        // A cron means Claude expects to wake itself later; hibernating would kill it.
        let status = AgentBackgroundWorkStatus(hookObject: [
            "background_tasks": [],
            "session_crons": [["id": "job1", "cron": "*/5 * * * *"]],
        ])
        #expect(status.isActive)
        #expect(status.scheduledCronCount == 1)
    }

    @Test("Only-terminal-status tasks are inactive")
    func terminalTasksAreInactive() {
        // Finished tasks normally vanish from the array, but if a terminal-status entry
        // lingers it must NOT block hibernation.
        for terminal in ["completed", "done", "failed", "error", "cancelled", "killed", "exited"] {
            let status = AgentBackgroundWorkStatus(hookObject: [
                "background_tasks": [runningTask(status: terminal)],
                "session_crons": [],
            ])
            #expect(!status.isActive, "Expected inactive for terminal status \(terminal)")
        }
    }

    @Test("Unknown/empty status fails safe to active")
    func unknownStatusFailsSafeActive() {
        // A task present with a status we don't recognize (or no status) is treated as
        // live: the safe direction is to NOT hibernate and risk killing real work.
        for unknown in ["", "queued", "pending", "in_progress", "weird-new-state"] {
            let status = AgentBackgroundWorkStatus(hookObject: [
                "background_tasks": [["id": "x", "status": unknown]],
            ])
            #expect(status.isActive, "Expected active for non-terminal status \(unknown.debugDescription)")
        }
        // A task object with no status key at all is still active.
        let noStatus = AgentBackgroundWorkStatus(hookObject: [
            "background_tasks": [["id": "x", "command": "sleep 99"]],
        ])
        #expect(noStatus.isActive)
    }

    @Test("Absent payloads are inactive (older clients keep hibernating)")
    func absentPayloadsAreInactive() {
        // Clients older than 2.1.145 never send these fields; hibernation must keep
        // working for them, so absence means "no background work".
        #expect(!AgentBackgroundWorkStatus(hookObject: nil).isActive)
        #expect(!AgentBackgroundWorkStatus(hookObject: [:]).isActive)
        #expect(!AgentBackgroundWorkStatus(hookObject: ["hook_event_name": "Stop"]).isActive)
    }

    @Test("Present-but-unreadable payloads fail closed as active")
    func unreadablePayloadsFailClosedActive() {
        // This payload is the only guard between hibernation's group SIGTERM and a live
        // background process. A field that is PRESENT but unparseable (schema drift to a
        // keyed object, an array of non-objects) is unreadable evidence of work — it must
        // keep the pane alive, never authorize the kill. Must not crash either.
        #expect(AgentBackgroundWorkStatus(hookObject: ["background_tasks": "nope"]).isActive)
        #expect(AgentBackgroundWorkStatus(hookObject: ["background_tasks": 7]).isActive)
        #expect(AgentBackgroundWorkStatus(hookObject: ["background_tasks": ["a", "b"]]).isActive)
        #expect(AgentBackgroundWorkStatus(hookObject: ["background_tasks": ["t1": ["status": "running"]]]).isActive)
        #expect(AgentBackgroundWorkStatus(hookObject: ["session_crons": "soon"]).isActive)
        // A readable terminal-status entry alongside unreadable garbage: garbage wins.
        #expect(AgentBackgroundWorkStatus(hookObject: [
            "background_tasks": [["status": "completed"], "garbage"],
        ]).isActive)
        // An EMPTY array is readable and clean: inactive.
        #expect(!AgentBackgroundWorkStatus(hookObject: ["background_tasks": [Any]()]).isActive)
    }

    @Test("Status matching ignores case and surrounding whitespace")
    func statusNormalization() {
        #expect(!AgentBackgroundWorkStatus(hookObject: [
            "background_tasks": [["status": "  COMPLETED  "]],
        ]).isActive)
        #expect(AgentBackgroundWorkStatus(hookObject: [
            "background_tasks": [["status": " Running "]],
        ]).isActive)
    }
}

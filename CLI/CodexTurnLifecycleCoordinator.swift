import Foundation

/// Owns the Codex hook boundary between process identity, child work, and
/// completion settlement. The generic hook adapter delegates here before it
/// mutates the resume/session snapshot or paints the pane.
struct CodexTurnLifecycleCoordinator {
    let ledger: CodexTurnLedger
    let invocation: CodexHookInvocation

    init(environment: [String: String], cli: CMUXCLI) {
        invocation = cli.codexHookInvocation(environment: environment)
        ledger = cli.codexTurnLedger(environment: environment)
    }

    func sessionStart(
        sessionID: String,
        workspaceID: String?,
        surfaceID: String?
    ) -> CodexTurnLedgerDecision {
        (try? ledger.sessionStart(
            sessionID: sessionID,
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            invocation: invocation
        )) ?? .ignored
    }

    func promptSubmit(
        sessionID: String,
        turnID: String?,
        workspaceID: String?,
        surfaceID: String?
    ) -> CodexTurnLedgerDecision {
        (try? ledger.promptSubmit(
            sessionID: sessionID,
            turnID: turnID,
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            invocation: invocation
        )) ?? .ignored
    }

    func subagent(
        sessionID: String,
        agentID: String?,
        turnID: String?,
        workspaceID: String?,
        surfaceID: String?,
        starts: Bool
    ) -> CodexTurnLedgerDecision {
        let result: Result<CodexTurnLedgerDecision, Error>
        if starts {
            result = Result {
                try ledger.subagentStart(
                    sessionID: sessionID,
                    agentID: agentID,
                    turnID: turnID,
                    workspaceID: workspaceID,
                    surfaceID: surfaceID,
                    invocation: invocation
                )
            }
        } else {
            result = Result {
                try ledger.subagentStop(
                    sessionID: sessionID,
                    agentID: agentID,
                    turnID: turnID,
                    workspaceID: workspaceID,
                    surfaceID: surfaceID,
                    invocation: invocation
                )
            }
        }
        return (try? result.get()) ?? .ignored
    }

    func stop(
        sessionID: String,
        turnID: String?,
        workspaceID: String?,
        surfaceID: String?
    ) -> CodexTurnLedgerDecision {
        (try? ledger.stop(
            sessionID: sessionID,
            turnID: turnID,
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            invocation: invocation
        )) ?? .ignored
    }

    func observe(
        sessionID: String,
        workspaceID: String?,
        surfaceID: String?
    ) -> CodexTurnLedgerDecision {
        (try? ledger.observe(
            sessionID: sessionID,
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            invocation: invocation
        )) ?? .ignored
    }

    func sessionEnd(
        sessionID: String,
        workspaceID: String?,
        surfaceID: String?
    ) -> CodexTurnLedgerDecision {
        (try? ledger.sessionEnd(
            sessionID: sessionID,
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            invocation: invocation
        )) ?? .ignored
    }

    /// Records a native feed lifecycle event before the feed frame is sent.
    /// Keeping this operation here ensures wrapper and persistent-feed
    /// producers share exactly the same owner/settlement path.
    func recordFeedLifecycle(
        sessionID: String,
        eventName: String,
        agentID: String?,
        turnID: String?,
        workspaceID: String?,
        surfaceID: String?
    ) -> CodexTurnLedgerDecision {
        subagent(
            sessionID: sessionID,
            agentID: agentID,
            turnID: turnID,
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            starts: eventName == "SubagentStart"
        )
    }
}

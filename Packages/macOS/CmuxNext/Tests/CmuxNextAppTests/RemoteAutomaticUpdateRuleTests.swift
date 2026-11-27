import CmuxNextRemote
import Testing

/// cx-3r9mt, Leo 2026-10-21 ("ACCEPT IT BREAKING AT SOME POINT BUT IT RESUMES WHATEVER IT
/// INTERRUPTED"): an older machine gets the app's build on connect even while it runs agents, so a
/// fix in the machine's cmux-tui reaches a busy machine without a click.
@Suite struct RemoteAutomaticUpdateRuleTests {
    private func status(_ fields: String) -> RemoteAgentDaemonStatus {
        RemoteAgentDaemonStatus(json: #"{"running":true,"ready":true,"agentHosts":true,"# + fields + "}")!
    }

    @Test func aMachineRunningAgentsAndPeerSessionsIsUpdated() {
        let busy = status(#""liveAgents":3,"remoteSessions":1,"personKey":false"#)
        #expect(busy.mayUpdateAutomatically(ownInstance: nil))
    }

    @Test func aMachineHoldingThisAppsOwnKeyIsUpdated() {
        let ours = status(#""liveAgents":1,"remoteSessions":0,"personKey":true,"personInstance":"mac-a""#)
        #expect(ours.mayUpdateAutomatically(ownInstance: "mac-a"))
    }

    @Test func aMachineHoldingAnotherClientsKeyIsLeftToThePerson() {
        let theirs = status(#""liveAgents":0,"remoteSessions":0,"personKey":true,"personInstance":"mac-b""#)
        #expect(!theirs.mayUpdateAutomatically(ownInstance: "mac-a"))
    }

    @Test func aMachineWithNoAgentDaemonIsUpdated() {
        let stopped = RemoteAgentDaemonStatus(json: #"{"running":false,"personKey":true,"personInstance":"mac-b"}"#)!
        #expect(stopped.mayUpdateAutomatically(ownInstance: "mac-a"))
    }
}

/// The handoff after an install stops the machine's agent daemon as an update restart, so a chat
/// waiting on a provider retry resumes in the new run (a plain shutdown records
/// `auto_resume_stopped`, and the new run does not resume it).
@Suite struct RemoteAgentDaemonHandoffCommandTests {
    @Test func theHandoffAsksForAnUpdateRestart() {
        let command = RemoteAgentDaemonStatus.shutdownKeepingAgents(binary: "~/.local/bin/cmux-tui")
        #expect(command.hasPrefix("out=$(~/.local/bin/cmux-tui acp daemon shutdown --keep-agents --restart </dev/null 2>&1)"))
    }

    @Test func anOlderCLIWithoutRestartFallsBackToKeepAgents() {
        let command = RemoteAgentDaemonStatus.shutdownKeepingAgents(binary: "~/.local/bin/cmux-tui")
        #expect(command.contains(#"*"unexpected argument '--restart'"*) ~/.local/bin/cmux-tui acp daemon shutdown --keep-agents </dev/null"#))
    }
}

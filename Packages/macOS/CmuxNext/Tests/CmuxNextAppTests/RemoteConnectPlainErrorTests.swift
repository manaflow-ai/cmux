@testable import CmuxNextApp
import Testing

/// "Cannot Connect" says what happened in a sentence, never the daemon's raw text (lock paths,
/// `try_lock`, `--session NAME`, log paths). Copy Error still copies the raw text (`sshError`).
/// User 2026-10-31 (Chief msg 19277): the sheet showed the remote daemon's whole error.
@Suite struct RemoteConnectPlainErrorTests {
    static let sessionInUse = """
        remote mux owner exited exit status: 1: this session on the machine is in use by another cmux daemon \
        (workspace session is already owned by another daemon: /Users/cmux-lawrence/Library/Application Support/\
        cmux-tui/sessions/session-locks/main-1f5962a2ce9803c8.lock: try_lock failed because the operation would block); \
        connect with another session name (--session NAME); inspect /Users/cmux-lawrence/Library/Application Support/\
        cmux/remote/sessions/bWFpbg/daemon.log
        """

    @Test func aSessionAnotherDaemonOwnsSaysUpdateTheMachine() {
        let text = RemoteStrings.plainFailure(Self.sessionInUse, machine: "cmux-lawrence")
        #expect(text == "Another cmux on cmux-lawrence holds this session. Update cmux on cmux-lawrence, then choose Retry.")
    }

    @Test func anUnknownFailureKeepsItsFirstClauseWithoutPaths() {
        let text = RemoteStrings.plainFailure("remote mux owner exited exit status: 1: disk full (/var/tmp/x.sock: errno 28); inspect /Users/a/daemon.log",
                                              machine: "box")
        #expect(text == "cmux on box stopped: disk full. Choose Copy Error for the details.")
        for raw in ["/Users/", "try_lock", "--session", "daemon.log", "exit status"] {
            #expect(!RemoteStrings.plainFailure(Self.sessionInUse, machine: "m").contains(raw))
            #expect(!text.contains(raw))
        }
    }
}

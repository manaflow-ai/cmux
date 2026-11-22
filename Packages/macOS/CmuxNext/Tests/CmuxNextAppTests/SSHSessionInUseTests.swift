import CmuxNextRemote
import Testing

/// A link whose session on the machine is owned by another cmux daemon (the
/// machine's own app or a Chief brain holds `main`) fails the same way on
/// every try: the app says so and waits for Reconnect instead of redialing
/// every 30 seconds.
@Suite struct SSHSessionInUseTests {
    /// What `cmux-tui remote connect` prints when the machine's mux owner
    /// exits on an owned session (cmux-tui `wait_for_detached_socket`).
    static let stderr = """
        cmux-tui: remote mux owner exited exit status: 1: this session on the machine is in use by another cmux daemon \
        (workspace session is already owned by another daemon: /s/main-1f.lock); connect with another session name \
        (--session NAME); inspect /h/daemon.log
        cmux-tui: all remote route candidates failed: ssh://box: link closed during handshake
        """

    @Test func theLinkFailureNamesTheSessionInUse() throws {
        let failure = try #require(SSHFailure.classifyLink(stderr: Self.stderr))
        #expect(failure.message.contains("in use by another cmux daemon"))
        #expect(SSHLinkError.ssh(failure).waitsForUser)
    }

    @Test func theMachineWaitsForReconnectNotATimerOrANetworkChange() throws {
        let failure = try #require(SSHFailure.classifyLink(stderr: Self.stderr))
        var machine = SSHConnectionMachine()
        machine.handle(.connect)
        machine.handle(.failed(failure))
        guard case .failed(let text) = machine.status else {
            Issue.record("status is \(machine.status), not failed")
            return
        }
        #expect(text.contains("--session"))
        #expect(!machine.mayAttempt)
        machine.handle(.wake(.networkChanged))
        #expect(!machine.mayAttempt)
        machine.handle(.wake(.appActivated))
        #expect(!machine.mayAttempt)
        machine.handle(.wake(.user))
        #expect(machine.mayAttempt)
    }

    @Test func anotherRemoteFailureStillRetries() throws {
        let failure = try #require(SSHFailure.classifyLink(stderr: "cmux-tui: link closed during handshake"))
        var machine = SSHConnectionMachine()
        machine.handle(.connect)
        machine.handle(.failed(failure))
        #expect(machine.mayAttempt)
        #expect(!SSHLinkError.ssh(failure).waitsForUser)
    }

    @Test func anUnreachableFailureCanStartAnotherAttemptAfterRetry() throws {
        let failure = SSHFailure.unreachable("nohost.invalid")
        var machine = SSHConnectionMachine()
        machine.handle(.connect)
        machine.handle(.failed(failure))
        #expect(machine.status == .unreachable("nohost.invalid"))
        #expect(machine.mayAttempt)
        machine.handle(.connect)
        #expect(machine.status == .connecting)
        #expect(machine.mayAttempt)
    }

    @Test func anAutomaticAttemptReopensTheGateAfterTransportFailure() {
        var machine = SSHConnectionMachine()
        machine.handle(.connect)
        machine.handle(.failed(.unreachable("nohost.invalid")))
        machine.handle(.attemptStarted)
        #expect(machine.status == .connecting)
    }

    @Test func anAutomaticAttemptDoesNotReopenAnAuthFailureGate() {
        var machine = SSHConnectionMachine()
        machine.handle(.connect)
        machine.handle(.failed(.authFailed("denied")))
        machine.handle(.attemptStarted)
        #expect(machine.status == .authFailed("denied"))
        #expect(!machine.mayAttempt)
    }

    @Test func userRetryLeavesARecoverableFailureForTheNewAttempt() {
        var machine = SSHConnectionMachine()
        machine.handle(.connect)
        machine.handle(.failed(.authFailed("denied")))
        machine.handle(.wake(.user))
        #expect(machine.status == .connecting)
        #expect(machine.mayAttempt)
    }
}

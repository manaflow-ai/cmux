@testable import CmuxNextRemote
import Testing

@Suite struct SSHConnectionMachineTests {
    @Test func startsOfflineAndNeverDialsUntilAsked() {
        var machine = SSHConnectionMachine()
        #expect(machine.status == .offline)
        #expect(!machine.mayAttempt)
        for wake in [SSHConnectionMachine.Wake.appActivated, .systemWake, .networkChanged] {
            machine.handle(.wake(wake))
            #expect(!machine.mayAttempt, "a \(wake) event must not connect a machine the user did not connect")
        }
        machine.handle(.connect)
        #expect(machine.status == .connecting)
        #expect(machine.mayAttempt)
    }

    @Test func connectedAndLostGoBackToConnecting() {
        var machine = SSHConnectionMachine()
        machine.handle(.connect)
        machine.handle(.probed(.none))
        #expect(machine.status == .connecting)
        machine.handle(.linkUp)
        #expect(machine.status == .connected)
        machine.handle(.linkLost)
        #expect(machine.status == .connecting)
        #expect(machine.mayAttempt)
    }

    @Test func unreachableKeepsRetryingOnTheSharedBackoff() {
        var machine = SSHConnectionMachine()
        machine.handle(.connect)
        machine.handle(.failed(.unreachable("No route to host")))
        #expect(machine.status == .unreachable("No route to host"))
        // The daemon loop's capped Backoff (then events only) paces retries;
        // the gate stays open so a network change reconnects at once.
        #expect(machine.mayAttempt)
        machine.handle(.attemptStarted)
        #expect(machine.status == .unreachable("No route to host"), "the error stays visible while retrying")
        machine.handle(.linkUp)
        #expect(machine.status == .connected)
    }

    @Test func authFailureWaitsForTheUserNotTheNetwork() {
        var machine = SSHConnectionMachine()
        machine.handle(.connect)
        machine.handle(.failed(.authFailed("Permission denied (publickey).")))
        #expect(machine.status == .authFailed("Permission denied (publickey)."))
        #expect(!machine.mayAttempt)
        machine.handle(.wake(.networkChanged))
        #expect(!machine.mayAttempt, "a network change cannot fix a key")
        machine.handle(.wake(.appActivated))
        #expect(machine.mayAttempt, "the user may have fixed their key or agent in another app")
        machine.handle(.failed(.authFailed("Permission denied (publickey).")))
        #expect(!machine.mayAttempt)
        machine.handle(.wake(.systemWake))
        #expect(machine.mayAttempt)
    }

    @Test func untrustedHostKeyBehavesLikeAuthFailure() {
        var machine = SSHConnectionMachine()
        machine.handle(.connect)
        machine.handle(.failed(.hostKeyUntrusted("Host key verification failed.")))
        #expect(machine.status == .hostKeyUntrusted("Host key verification failed."))
        #expect(!machine.mayAttempt)
        machine.handle(.wake(.user))
        #expect(machine.mayAttempt)
    }

    @Test func missingOrOldCmuxTuiWaitsForInstallOrTheUser() {
        var machine = SSHConnectionMachine()
        machine.handle(.connect)
        machine.handle(.probed(.missing))
        #expect(machine.status == .needsInstall(.missing))
        #expect(!machine.mayAttempt)
        machine.handle(.wake(.networkChanged))
        machine.handle(.wake(.systemWake))
        #expect(!machine.mayAttempt)
        machine.handle(.installStarted)
        #expect(machine.status == .installing)
        #expect(!machine.mayAttempt, "no link while the binary is replaced")
        machine.handle(.installFinished(.success))
        #expect(machine.status == .connecting)
        #expect(machine.mayAttempt)
    }

    @Test func aFailedInstallIsShownAndRetriedOnlyByTheUser() {
        var machine = SSHConnectionMachine()
        machine.handle(.connect)
        machine.handle(.probed(.protocolMismatch(remote: 4, local: 5)))
        machine.handle(.installStarted)
        machine.handle(.installFinished(.failure("checksum mismatch")))
        #expect(machine.status == .installFailed("checksum mismatch"))
        #expect(!machine.mayAttempt)
        machine.handle(.wake(.appActivated))
        #expect(!machine.mayAttempt)
        machine.handle(.wake(.user))
        #expect(machine.mayAttempt)
    }

    @Test func activationRetriesAMachineThatNeededAnInstall() {
        // The user may have installed cmux-tui from a terminal meanwhile.
        var machine = SSHConnectionMachine()
        machine.handle(.connect)
        machine.handle(.probed(.missing))
        machine.handle(.wake(.appActivated))
        #expect(machine.mayAttempt)
    }

    @Test func disconnectStopsEverythingUntilConnect() {
        var machine = SSHConnectionMachine()
        machine.handle(.connect)
        machine.handle(.linkUp)
        machine.handle(.disconnect)
        #expect(machine.status == .offline)
        #expect(!machine.mayAttempt)
        machine.handle(.failed(.unreachable("late failure of the old link")))
        #expect(machine.status == .offline, "results of an abandoned attempt do not resurrect the machine")
        machine.handle(.linkUp)
        #expect(machine.status == .offline)
        machine.handle(.connect)
        #expect(machine.mayAttempt)
    }

    @Test func otherFailuresRetry() {
        var machine = SSHConnectionMachine()
        machine.handle(.connect)
        machine.handle(.failed(.remoteFailed("sh: broken")))
        #expect(machine.status == .failed("sh: broken"))
        #expect(machine.mayAttempt)
    }
}

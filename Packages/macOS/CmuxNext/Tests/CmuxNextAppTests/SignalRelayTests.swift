import Darwin
import Testing
@testable import CmuxNextApp

/// `SignalRelay`, the mechanism behind `QuitSignal`: a requested-quit signal
/// reaches the main queue, the process survives it, and children the app
/// starts still get the signal's default action. SIGUSR2 stands in for
/// SIGTERM, SIGINT and SIGHUP so the test process keeps its own handling of
/// those (`AppRunMarker` tests install handlers for them).
@MainActor
@Suite(.serialized) struct SignalRelayTests {
    @MainActor
    private final class Inbox {
        private var received: [Int32] = []
        private var waiter: CheckedContinuation<Int32, Never>?

        func deliver(_ signal: Int32) {
            if let waiter {
                self.waiter = nil
                waiter.resume(returning: signal)
            } else {
                received.append(signal)
            }
        }

        func next() async -> Int32 {
            if !received.isEmpty { return received.removeFirst() }
            return await withCheckedContinuation { waiter = $0 }
        }
    }

    private static func disposition(_ signal: Int32) -> sigaction {
        var action = sigaction()
        sigaction(signal, nil, &action)
        return action
    }

    private static func handlerAddress(_ action: sigaction) -> Int {
        unsafeBitCast(action.__sigaction_u.__sa_handler, to: Int.self)
    }

    /// Runs `/bin/sh -c "kill -USR2 $$; exit 0"` with plain posix_spawn (no
    /// POSIX_SPAWN_SETSIGDEF, like forkpty) and returns the signal that
    /// ended it, or nil when it exited.
    private static func childSelfSignal() -> Int32? {
        let arguments = ["/bin/sh", "-c", "kill -USR2 $$; exit 0"]
        var argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) } + [nil]
        defer { for pointer in argv { free(pointer) } }
        var pid: pid_t = 0
        guard posix_spawn(&pid, "/bin/sh", nil, nil, &argv, environ) == 0 else { return -1 }
        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
        let terminating = status & 0x7f
        return terminating != 0 && terminating != 0x7f ? terminating : nil
    }

    @Test(.timeLimit(.minutes(1)))
    func aSignalReachesTheMainQueueAndTheProcessSurvives() async {
        let inbox = Inbox()
        let relay = SignalRelay(signals: [SIGUSR2]) { inbox.deliver($0) }
        defer { relay.cancel() }
        kill(getpid(), SIGUSR2)
        #expect(await inbox.next() == SIGUSR2)
        kill(getpid(), SIGUSR2)
        #expect(await inbox.next() == SIGUSR2)
    }

    /// Caught, not ignored: an ignored signal stays ignored in every child
    /// the app execs, so its shells would ignore Ctrl-C and `kill`.
    @Test func theSignalIsCaughtSoChildrenGetTheDefaultAction() {
        let relay = SignalRelay(signals: [SIGUSR2]) { _ in }
        defer { relay.cancel() }
        let address = Self.handlerAddress(Self.disposition(SIGUSR2))
        #expect(address != unsafeBitCast(SIG_IGN, to: Int.self))
        #expect(address != unsafeBitCast(SIG_DFL, to: Int.self))
        #expect(Self.childSelfSignal() == SIGUSR2)
    }

    /// Chromium resets signal actions when it starts; `catchSignals` takes
    /// them back.
    @Test func catchSignalsTakesTheSignalBackAfterAReset() {
        let relay = SignalRelay(signals: [SIGUSR2]) { _ in }
        defer { relay.cancel() }
        let caught = Self.handlerAddress(Self.disposition(SIGUSR2))
        _ = signal(SIGUSR2, SIG_IGN)
        relay.catchSignals()
        #expect(Self.handlerAddress(Self.disposition(SIGUSR2)) == caught)
    }

    @Test func cancelRestoresTheDefaultAction() {
        let relay = SignalRelay(signals: [SIGUSR2]) { _ in }
        relay.cancel()
        #expect(Self.handlerAddress(Self.disposition(SIGUSR2)) == unsafeBitCast(SIG_DFL, to: Int.self))
    }

    @Test func quitSignalRelaysEveryRequestedQuitSignal() {
        #expect(LaunchRecovery.requestedQuitSignals == [SIGTERM, SIGINT, SIGHUP])
    }
}

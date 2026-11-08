@testable import CmuxNextApp
import CmuxNextBridge
import CmuxNextCompat
@testable import CmuxNextDaemon
@testable import CmuxNextDaemonService
import CmuxNextRemote
import Foundation
import Testing

/// cmuxterm-hq#7766 step 2: a remote machine's link (`cmux-tui remote connect`) is the only layer
/// that redials. The app made timed redials on top of it (a first-connect pacer nested in an outer
/// pacer, the connection's own reconnect loop, a network monitor, and a Reconnect that killed and
/// restarted the link client "with a new retry budget"), so one dead link became a burst of dials.
/// Now the app makes one attempt and then waits for the link's state or an event.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct RemoteLinkOneRedialerTests {
    /// Counts endpoint calls.
    private final class Calls: Sendable {
        private let count = Mutex(0)
        func hit() { count.withLock { $0 += 1 } }
        var value: Int { count.withLock { $0 } }
    }

    private static func service(_ calls: Calls, followsLink: Bool) -> DaemonService {
        let daemon = DaemonService(machineID: "ssh:one-redialer-\(UUID().uuidString)")
        daemon.start(remote: {
            calls.hit()
            throw DaemonError.notConnected
        }, followsLink: followsLink)
        return daemon
    }

    @Test func aLinkThatFollowsItsOwnStateGetsOneFirstAttemptAndNoTimedRetries() async throws {
        let calls = Calls()
        let daemon = Self.service(calls, followsLink: true)
        try await Task.sleep(for: .milliseconds(2000))
        daemon.shutdownConnection()
        #expect(calls.value == 1, "the app dialed a link that redials by itself \(calls.value) times")
    }

    /// The legacy route (a server's own socket or bridge, a Cloud ticket) still paces its own retries:
    /// this is what the link route no longer stacks on its link.
    @Test func theLegacyRouteStillRetriesOnATimer() async throws {
        let calls = Calls()
        let daemon = Self.service(calls, followsLink: false)
        try await Task.sleep(for: .milliseconds(2000))
        daemon.shutdownConnection()
        #expect(calls.value >= 2, "the legacy first-connect pacer made \(calls.value) attempts")
    }

    @Test func theLinksStateWakesTheWaitingAttemptOnce() async throws {
        let calls = Calls()
        let daemon = Self.service(calls, followsLink: true)
        try await Task.sleep(for: .milliseconds(1000))
        #expect(calls.value == 1, "the first attempt, and no timed retry")
        daemon.retryWake.fire()
        try await Task.sleep(for: .milliseconds(1000))
        #expect(calls.value == 2, "one wake (the link reported connected) makes exactly one attempt")
        daemon.shutdownConnection()
    }

    /// A machine unreachable at launch has no link process yet, so nothing in Rust watches its network:
    /// the network coming back still wakes its first attempt, with no app action.
    @Test func aNeverConnectedLinkStillWakesOnTheNetwork() async throws {
        let calls = Calls()
        let daemon = Self.service(calls, followsLink: true)
        #expect(daemon.watchesNetwork, "an SSH machine unreachable at launch would never come back by itself")
        daemon.shutdownConnection()
        #expect(!daemon.watchesNetwork)
    }

    /// The link reporting connected again, or its process exiting, wakes the daemon connection; other
    /// changes (a failure, an install) do not.
    @Test func onlyTheLinksUpAndLossWakeTheDaemon() {
        typealias S = SSHConnectionMachine.Status
        #expect(S.connected.wakesDaemon(after: .reconnecting))
        #expect(S.connected.wakesDaemon(after: .connecting))
        #expect(S.connecting.wakesDaemon(after: .connected), "the link process exited")
        #expect(S.connecting.wakesDaemon(after: .reconnecting), "the link process exited")
        #expect(!S.connecting.wakesDaemon(after: .offline))
        #expect(!S.reconnecting.wakesDaemon(after: .connected), "the link redials by itself")
        #expect(!S.unreachable("x").wakesDaemon(after: .connecting))
        #expect(!S.installing.wakesDaemon(after: .connecting))
    }

    /// The app no longer caps the link's attempts: `remote connect` stays up under its own budget.
    @Test func theLinkGetsNoAttemptCap() throws {
        let host = try SSHHost(destination: SSHDestination(parsing: "nohost.invalid"))
        let args = SSHCommandLine().link(host, clientStateDir: "/tmp/state", localSocket: "/tmp/link.sock")
        #expect(!args.contains("--reconnect-attempts"), "\(args)")
        #expect(args.contains("--local-socket"))
    }
}

/// A connection over a link that redials by itself (``RetryPolicy/linkReconnect``) makes one attempt
/// when it drops, then waits for an event; the timed reconnect policy made several in the same time.
@Suite(.serialized, .timeLimit(.minutes(1))) struct LinkReconnectPolicyTests {
    @Test func aDropGetsOneAttemptThenEventsOnly() {
        var pacer = RetryPacer(.linkReconnect)
        #expect(pacer.failed() != nil, "the drop's one attempt")
        #expect(pacer.failed() == nil, "a failed attempt waits for an event")
        #expect(pacer.waitsForEventOnly)
        var first = RetryPacer(.linkFirstConnect)
        #expect(first.failed() == nil, "a failed first attempt waits for an event")
    }
}

import CmuxNextCompat
import Foundation
import Testing
@testable import CmuxNextDaemon

/// cmux NIGHTLY on a loaded Mac (2026-10-29): the session daemon sat at its 64-connection limit
/// for minutes (45,195 refusals against 14,404 accepts) while CLI clients blocked on its registry
/// lock held the slots. The app's own connection dropped, and every reconnect read
/// `{"type":"refused","code":"server.busy"}` and EOF. The transport dropped that line, so the
/// refusal looked like a crash: ten timed retries later the reconnect waited for an event only,
/// a busy daemon behind the same socket fired none, and the app stayed "not connected", so every
/// GUI split and new pane snapped back.
///
/// A busy refusal now closes with ``LineTransport/busyRefusal`` (``DaemonError/isBusyRefusal``)
/// and spends no timed retry: the app keeps asking, at most ``RetryPacer/busyRetryCap`` apart.
@Suite struct BusyRefusalReconnectTests {
    @Test func aBusyRefusalSpendsNoTimedRetryAndIsAskedAgainSoon() {
        var pacer = RetryPacer(RetryPolicy(initial: .milliseconds(250), maximum: .seconds(30), timedRetries: 2))
        for attempt in 0..<50 {
            pacer.refusedBusy()
            let delay = pacer.failed()
            #expect(delay != nil, "busy refusal \(attempt) spent the budget: the reconnect would wait for an event only")
            #expect(delay.map { $0 <= RetryPacer.busyRetryCap } == true, "busy refusal \(attempt) spaced \(String(describing: delay))")
        }
        #expect(!pacer.isExhausted)
        #expect(pacer.failed() != nil, "another failure still has its timed retries")
        #expect(pacer.failed() != nil)
        #expect(pacer.failed() == nil, "a real failure still spends the budget")
    }

    /// Past the budget, a busy refusal still keeps a timed retry: the reconnect is not spent, so a
    /// remote machine's header does not read offline while its daemon is only busy (HQ #4877 G4).
    @Test func aBusyRefusalPastTheBudgetIsNotEventOnly() {
        var pacer = RetryPacer(RetryPolicy(initial: .milliseconds(250), maximum: .seconds(30), timedRetries: 1))
        _ = pacer.failed()
        #expect(pacer.waitsForEventOnly)
        pacer.refusedBusy()
        #expect(pacer.isExhausted)
        #expect(!pacer.waitsForEventOnly)
        _ = pacer.failed()
        #expect(pacer.waitsForEventOnly)
    }

    /// A busy refusal noted by a reconnect loop that then stopped does not make the next drop's
    /// first real failure free.
    @Test func aResetForgetsAnUnspentBusyRefusal() {
        var pacer = RetryPacer(RetryPolicy(initial: .milliseconds(250), maximum: .seconds(30), timedRetries: 1))
        pacer.refusedBusy()
        pacer.reset()
        #expect(pacer.failed() != nil, "the one timed retry")
        #expect(pacer.failed() == nil, "a stale busy refusal gave a real failure an extra retry")
    }

    /// The daemon closes a refused connection right after its line, so the hello's write can fail
    /// (broken pipe) before the reader routes the line: that failure is still a busy refusal.
    @Test func aRefusalWaitingUnreadIsSeenOnAFailedWrite() throws {
        func pair(_ daemonWrites: String) throws -> Int32 {
            var fds: [Int32] = [0, 0]
            try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
            let bytes = Array(daemonWrites.utf8)
            if !bytes.isEmpty { _ = bytes.withUnsafeBytes { write(fds[1], $0.baseAddress, $0.count) } }
            close(fds[1])
            return fds[0]
        }
        let refused = try pair(#"{"protocol":"cmux.protocol/2","type":"refused","code":"server.busy","message":"m"}"# + "\n")
        defer { close(refused) }
        #expect(LineTransport.hasPendingBusyRefusal(fd: refused))
        #expect(LineTransport.hasPendingBusyRefusal(fd: refused), "peeking leaves the line for the reader")
        let other = try pair(#"{"protocol":"cmux.protocol/2","type":"event","event":"x"}"# + "\n")
        defer { close(other) }
        #expect(!LineTransport.hasPendingBusyRefusal(fd: other))
        let empty = try pair("")
        defer { close(empty) }
        #expect(!LineTransport.hasPendingBusyRefusal(fd: empty))
    }

    /// Refuses its first `refusals` connections the way cmux-tui does at its connection limit (one
    /// `refused` line, then EOF), then serves the handshake.
    private static let script = #"""
    import json, os, sys
    count_file, refusals = sys.argv[1], int(sys.argv[2])
    count = int(open(count_file).read() or '0') if os.path.exists(count_file) else 0
    open(count_file, 'w').write(str(count + 1))
    print('{"ok":true}', file=sys.stderr, flush=True)
    if count < refusals:
        sys.stdin.readline()  # the handshake is written; cmux-tui refuses after accept, before it reads
        print('{"protocol":"cmux.protocol/2","type":"refused","code":"server.busy",'
              '"message":"the session is at its connection limit; retry"}', flush=True)
        sys.exit(0)
    for line in sys.stdin:
        frame = json.loads(line)
        if frame.get('cmd') == 'identify':
            data = {'app': 'cmux-tui', 'protocol': 12, 'generation': 'busy-refusal-test', 'capabilities': []}
        else:
            data = {}
        print(json.dumps({'id': frame.get('id'), 'ok': True, 'data': data}), flush=True)
    """#

    private func connection(counting countFile: String, refusals: Int) -> DaemonConnection {
        let bridge = DaemonBridge(executable: "/usr/bin/python3", arguments: ["-u", "-c", Self.script, countFile, String(refusals)])
        return DaemonConnection(
            endpoint: .init(socketPath: "/tmp/cmux-busy-refusal-test-\(UUID().uuidString).sock", bridge: bridge),
            configuration: .init(requiredCapabilities: [], requestTimeout: .seconds(2), spawnTimeout: .seconds(2),
                                 terminalEnvironment: nil))
    }

    private final class Failures: Sendable {
        private let seen = Mutex([String]())
        func append(_ text: String) { seen.withLock { $0.append(text) } }
        var all: [String] { seen.withLock { $0 } }
    }

    private func countFile() -> String {
        FileManager.default.temporaryDirectory.appendingPathComponent("cmux-busy-refusal-\(UUID().uuidString)").path
    }

    @Test func aRefusedConnectionSaysTheDaemonIsBusy() async throws {
        let file = countFile()
        defer { try? FileManager.default.removeItem(atPath: file) }
        let connection = connection(counting: file, refusals: 1)
        do {
            try await connection.start()
            Issue.record("a refused connection started")
        } catch let error as DaemonError {
            #expect(error.isBusyRefusal, "the refusal read as \(error.description)")
        }
        await connection.close()
    }

    /// More busy refusals than the timed budget: the connect keeps asking and gets in once the
    /// daemon has a free slot, instead of parking until an event that never comes.
    @Test func aDaemonBusyPastTheBudgetIsStillReached() async throws {
        let file = countFile()
        defer { try? FileManager.default.removeItem(atPath: file) }
        let refusals = 5
        let policy = RetryPolicy(initial: .milliseconds(20), maximum: .milliseconds(50), timedRetries: 2)
        let failures = Failures()
        let connected = await withTaskGroup(of: DaemonConnection?.self) { group in
            group.addTask {
                await DaemonStartup.shared.connect(
                    policy: policy, wake: RetryWake(owner: "BusyRefusalReconnectTests"),
                    makeConnection: { connection(counting: file, refusals: refusals) },
                    onFailure: { error in failures.append(error.description) }
                )?.0
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(30))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        let seen = failures.all
        #expect(connected != nil, "the connect parked after \(seen.count) busy refusals: \(seen)")
        #expect(seen.count == refusals)
        #expect(seen.allSatisfy { $0 == DaemonError.connectionClosed(reason: LineTransport.busyRefusal).description })
        await connected?.close()
    }
}

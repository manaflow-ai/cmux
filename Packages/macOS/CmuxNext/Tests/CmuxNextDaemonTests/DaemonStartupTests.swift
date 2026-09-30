import Foundation
import Synchronization
import Testing
@testable import CmuxNextDaemon

/// The first connect retries. Before `DaemonStartup`, one failed first
/// attempt left the app with no connection until it was relaunched.
@Suite(.timeLimit(.minutes(1))) struct DaemonStartupTests {
    @Test func firstConnectRetriesUntilTheDaemonAnswers() async throws {
        let server = try FakeDaemonServer(handler: ConnectionTests.handshake { _, _ in [] })
        defer { server.stop() }
        let attempts = Mutex(0)
        let failures = Mutex<[DaemonError]>([])
        let result = await DaemonStartup.connect(clock: ImmediateClock()) {
            DaemonConnection(configuration: DaemonConnection.Configuration(backoff: [], terminalEnvironment: nil)) {
                let attempt = attempts.withLock { value -> Int in
                    value += 1
                    return value
                }
                // A rival owner holding the session lock, then a slow ensure.
                if attempt == 1 { throw DaemonError.launchFailed("exit 1: the detached session owner did not become ready") }
                if attempt == 2 { throw DaemonError.timedOut("cmux-tui --session s --json server ensure") }
                return DaemonEndpoint(socketPath: server.path)
            }
        } onFailure: { error in
            failures.withLock { $0.append(error) }
        }
        let (connection, identity) = try #require(result)
        #expect(identity.app == "cmux-tui")
        #expect(await connection.isReady)
        #expect(attempts.withLock { $0 } == 3)
        #expect(failures.withLock { $0.count } == 2)
        await connection.close()
    }

    @Test func incompatibleDaemonStopsRetrying() async {
        let attempts = Mutex(0)
        let result = await DaemonStartup.connect(clock: ImmediateClock()) {
            DaemonConnection(configuration: DaemonConnection.Configuration(backoff: [], terminalEnvironment: nil)) {
                attempts.withLock { $0 += 1 }
                throw DaemonError.binaryNotFound(searched: ["/nope"])
            }
        } onFailure: { _ in }
        #expect(result == nil)
        #expect(attempts.withLock { $0 } == 1)
    }

    @Test func cancellationEndsTheLoop() async {
        let task = Task {
            await DaemonStartup.connect(delays: [.seconds(60)]) {
                DaemonConnection(configuration: DaemonConnection.Configuration(backoff: [], terminalEnvironment: nil)) {
                    throw DaemonError.launchFailed("down")
                }
            } onFailure: { _ in }
        }
        task.cancel()
        let result = await task.value
        #expect(result == nil)
    }
}

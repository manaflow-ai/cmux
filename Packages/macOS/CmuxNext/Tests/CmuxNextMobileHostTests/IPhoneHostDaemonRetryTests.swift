import CmuxNextCompat
import CmuxNextMobile
@testable import CmuxNextMobileHost
import CmuxNextWakeupsTestSupport
import Foundation
import Observation
import Synchronization
import Testing

/// The iPhone host's wait for cmux-tui at launch (2026-11-05: the app asked for the daemon's socket
/// before it was connected, gave up, and never started hostd, so every phone showed the Mac asleep
/// or offline while it was awake, and the Mobile Pairing page never reached its QR code).
@MainActor @Suite(.timeLimit(.minutes(1))) struct IPhoneHostDaemonRetryTests {
    @Observable @MainActor final class Toggle {
        var on = true
    }

    /// The socket asks the host made; the first `failures` find cmux-tui not connected.
    nonisolated final class Socket: Sendable {
        private let state = Mutex<(asks: Int, failures: Int)>((0, 0))
        init(failures: Int) { state.withLock { $0.failures = failures } }
        var asks: Int { state.withLock { $0.asks } }
        func ask() throws -> String {
            let fail = state.withLock { state in
                state.asks += 1
                return state.asks <= state.failures
            }
            if fail { throw DaemonErrorStandIn.notConnected }
            return "/nonexistent/daemon.sock"
        }
    }

    /// What the wiring's `daemonSocket` throws before cmux-tui connects (DaemonError.notConnected's text).
    enum DaemonErrorStandIn: Error, CustomStringConvertible {
        case notConnected
        var description: String { "not connected to cmux-tui" }
    }

    /// The identity reads past the socket: this suite starts no hostd, so the read stops there.
    nonisolated final class Reads: Sendable {
        private let count = Mutex(0)
        var reads: Int { count.withLock { $0 } }
        func read() throws -> MobileHostMacIdentity {
            count.withLock { $0 += 1 }
            throw CancellationError()
        }
    }

    static func host(socket: Socket, reads: Reads, clock: ManualClock, directory: URL) -> IPhoneHostService {
        let host = IPhoneHostService(loginKeychain: LoginKeychain(), pairedStore: MobileHostPairedStore(seal: MobileHostMemoryPairingSeal()))
        host.identityRetryClock = clock
        host.dependencies = .init(executable: URL(fileURLWithPath: "/nonexistent/cmux-mobile-host"),
                                  baseURL: URL(string: "https://mobile.invalid")!, stackProjectID: "test",
                                  stateDirectory: directory, accessToken: { _ in throw CancellationError() },
                                  daemonSocket: { try socket.ask() }, acpmux: { nil }, fileRoots: { [] },
                                  computerName: { "Mac" }, macIdentity: { _ in try reads.read() })
        return host
    }

    static let account = IPhoneHostService.Account(userID: "user", teamID: "team", teamName: nil, email: nil)

    static func until(_ condition: @MainActor () -> Bool) async {
        while !condition() { await Task.yield() }
    }

    /// cmux-tui not connected yet: the host waits on the backoff and asks again, and starts once
    /// the socket is there (before the fix it asked once and never again).
    @Test func aMissingDaemonSocketIsAskedAgainUntilItIsThere() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let socket = Socket(failures: 3), reads = Reads(), clock = ManualClock(), toggle = Toggle()
        let host = Self.host(socket: socket, reads: reads, clock: clock, directory: directory)
        defer { host.stop() }
        host.follow(allowed: { toggle.on })
        host.accountChanged(Self.account)
        for (attempt, base) in [1.0, 2, 4].enumerated() {
            try await clock.waitForSleeper()
            #expect(socket.asks == attempt + 1)
            #expect(reads.reads == 0)
            let wait = try #require(clock.sleeperDeadlines.first).offset - clock.now.offset
            #expect(wait >= .seconds(base * 0.8) && wait <= .seconds(base * 1.2))
            await Self.until { host.phase == .waiting("not connected to cmux-tui") }
            clock.advance(by: wait)
        }
        // The fourth ask finds the socket: the start goes on to this Mac's identity.
        await Self.until { reads.reads == 1 }
        #expect(socket.asks == 4)
    }

    /// Turning iPhone connections off while it waits ends the wait: no ask follows.
    @Test func turningConnectionsOffEndsTheDaemonWait() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let socket = Socket(failures: .max), reads = Reads(), clock = ManualClock(), toggle = Toggle()
        let host = Self.host(socket: socket, reads: reads, clock: clock, directory: directory)
        defer { host.stop() }
        host.follow(allowed: { toggle.on })
        host.accountChanged(Self.account)
        try await clock.waitForSleeper()
        toggle.on = false
        await Self.until { host.phase == .off && clock.sleeperCount == 0 }
        clock.advance(by: .seconds(60))
        for _ in 0..<50 { await Task.yield() }
        #expect(socket.asks == 1)
    }
}

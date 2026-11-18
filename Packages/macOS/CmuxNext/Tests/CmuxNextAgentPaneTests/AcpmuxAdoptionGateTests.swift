import Foundation
import os
import Testing
@testable import CmuxNextAgentPane

/// A relaunched chat's handshake waited for this launch's build-home adoption (cx-is1kf.9) before it
/// asked the daemon anything, with up to 300 s of limit, even when the daemon already answered and the
/// adoption had nothing left to do for its home. A home the adoption no longer changes is looked up at
/// once; one it may still change waits a bounded time, then fails as restarting, which the page retries.
@Suite(.serialized)
struct AcpmuxAdoptionGateTests {
    /// A live daemon and an adoption that never ends on its own: the handshake connects without it.
    @Test func aSettledHomeConnectsWithoutWaitingForTheAdoption() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let adoption = AsyncStream<Void>.makeStream()
        let gate = AcpmuxAdoptionGate(mayChange: { _ in false }, untilEnded: { for await _ in adoption.stream {} }, limit: .seconds(3600))
        let host = AcpmuxHost(daemons: AcpmuxLocalDaemons(), resolve: { fixture.environment },
                              enrollComputerUse: { _ in }, adoption: gate)

        let outcome = await Self.withAdoptionReleased(after: .seconds(20), adoption.continuation) {
            try await host.reconnectHandshake(sessionId: "s")
        }
        #expect(!outcome.released, "the handshake waited for the adoption")
        #expect(try outcome.result.get().connection?.url.port == 9, "the handshake did not connect to the live daemon")
    }

    /// A home the adoption may still move: the lookup asks the daemon nothing while the adoption runs,
    /// and fails as restarting (transient: the page retries and says so once it lasts) after the limit.
    @Test func aHomeTheAdoptionMayChangeWaitsABoundedTime() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let adoption = AsyncStream<Void>.makeStream()
        let gate = AcpmuxAdoptionGate(mayChange: { _ in true }, untilEnded: { for await _ in adoption.stream {} }, limit: .milliseconds(300))
        let host = AcpmuxHost(daemons: AcpmuxLocalDaemons(), resolve: { fixture.environment },
                              enrollComputerUse: { _ in }, adoption: gate)

        let outcome = await Self.withAdoptionReleased(after: .seconds(20), adoption.continuation) {
            try await host.reconnectHandshake(sessionId: "s")
        }
        #expect(!outcome.released, "the lookup waited for the adoption past its limit")
        #expect(throws: AgentPaneHostError.daemonRestarting) { try outcome.result.get() }
        #expect(AgentPaneHostError.daemonRestarting.isTransient)
        #expect(fixture.daemon.methods.isEmpty, "the lookup asked a daemon the adoption may stop: \(fixture.daemon.methods)")
    }

    /// The adoption ends within the limit: the lookup goes on and connects.
    @Test func aHomeTheAdoptionMayChangeConnectsOnceTheAdoptionEnds() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let gate = AcpmuxAdoptionGate(mayChange: { _ in true }, untilEnded: {}, limit: .seconds(3600))
        let host = AcpmuxHost(daemons: AcpmuxLocalDaemons(), resolve: { fixture.environment },
                              enrollComputerUse: { _ in }, adoption: gate)
        #expect(try await host.reconnectHandshake(sessionId: "s").connection?.url.port == 9)
    }

    /// The disk rules mirror cmux-tui `build_adopt`'s "nothing to do".
    @Test func whetherTheAdoptionMayChangeAHome() throws {
        let root = URL(fileURLWithPath: "/tmp/aag-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let acpmux = root.appending(path: ".acpmux", directoryHint: .isDirectory)
        let home = acpmux.appending(path: "builds/k1", directoryHint: .isDirectory)
        let legacy = acpmux.appending(path: "tags/cmux-next", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)

        // No old home: nothing to adopt.
        #expect(!AcpmuxAdoptionGate.mayChange(home: home))
        // An old home, a real directory, and no record: the adoption moves it in.
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        #expect(AcpmuxAdoptionGate.mayChange(home: home))
        // The record: done.
        let record = home.appending(path: "adopted.json", directoryHint: .notDirectory)
        try Data("{}".utf8).write(to: record)
        #expect(!AcpmuxAdoptionGate.mayChange(home: home))
        // The link an adoption leaves at the old path is no home to adopt.
        try FileManager.default.removeItem(at: record)
        try FileManager.default.removeItem(at: legacy)
        try FileManager.default.createSymbolicLink(at: legacy, withDestinationURL: home)
        #expect(!AcpmuxAdoptionGate.mayChange(home: home))
        // NIGHTLY's shared home is never adopted.
        #expect(!AcpmuxAdoptionGate.mayChange(home: acpmux))

        // A NEXT Chief home's acpmux waits for the Chief home's record.
        let chief = root.appending(path: ".cmux/chief/com.cmuxterm.app.nightly.cmux-next.acct", directoryHint: .isDirectory)
        let chiefAcpmux = chief.appending(path: "acpmux", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: chiefAcpmux, withIntermediateDirectories: true)
        #expect(AcpmuxAdoptionGate.mayChange(home: chiefAcpmux))
        try Data("{}".utf8).write(to: chief.appending(path: "adopted.json", directoryHint: .notDirectory))
        #expect(!AcpmuxAdoptionGate.mayChange(home: chiefAcpmux))
        // Another build's Chief home is never adopted.
        let other = root.appending(path: ".cmux/chief/default/acpmux", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        #expect(!AcpmuxAdoptionGate.mayChange(home: other))
    }

    // MARK: - Fixtures

    /// Runs `body`; after `limit` ends the adoption (so a body that waits on it ends too) and says so.
    static func withAdoptionReleased<T: Sendable>(after limit: Duration, _ adoption: AsyncStream<Void>.Continuation,
                                                  _ body: @escaping @Sendable () async throws -> T) async
        -> (result: Result<T, any Error>, released: Bool) {
        let released = OSAllocatedUnfairLock(initialState: false)
        // task-owner: cancelled below once the body settles
        let watchdog = Task {
            try await Task.sleep(for: limit)
            released.withLock { $0 = true }
            adoption.finish()
        }
        // task-owner: awaited below
        let result = await Task { try await body() }.result
        watchdog.cancel()
        adoption.finish()
        return (result, released.withLock { $0 })
    }

    /// A live daemon (``AcpmuxSlowDaemonTests/SlowDaemon``, answering at once) on an attached home.
    struct Fixture {
        let root: URL
        let environment: AcpmuxEnvironment
        let daemon: AcpmuxSlowDaemonTests.SlowDaemon

        init() throws {
            root = URL(fileURLWithPath: "/tmp/aag-\(UUID().uuidString.prefix(8))", isDirectory: true)
            let home = root.appendingPathComponent("home", isDirectory: true)
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            environment = AcpmuxEnvironment(executable: try AcpmuxSlowDaemonTests.ownExecutable(), home: home,
                                            socketPath: home.appendingPathComponent("s.sock").path,
                                            daemonArguments: [], childEnvironment: [:]).attached(to: home)
            daemon = try AcpmuxSlowDaemonTests.SlowDaemon(socketPath: environment.socketPath, home: home.path, statusDelay: .zero)
        }

        func remove() {
            daemon.stop()
            try? FileManager.default.removeItem(at: root)
        }
    }
}

@testable import CmuxNextAgentPane
@testable import CmuxNextCompat
import CmuxNextWakeups
import Foundation
import Testing

/// The acpmux client's blocking calls run on a lane or a queue of their own, never on the main thread or the
/// cooperative pool (plans/cmux-next/chrome-parity/p02-threads.md, task 060, the MQ-1 recipe): the Chief tab
/// router's kept-session check, the pane host's `daemon.pid` read, the person line's socket check and proof.
@MainActor @Suite(.serialized)
struct AcpmuxBlockingLanesTests {
    /// A short acpmux home (a socket path must fit in `sun_path`) with no daemon on its socket.
    private static func environment() throws -> AcpmuxEnvironment {
        let home = URL(fileURLWithPath: "/tmp/abl-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return AcpmuxEnvironment(executable: URL(fileURLWithPath: "/usr/bin/false"), home: home,
                                 socketPath: home.appendingPathComponent("acpmux.sock").path,
                                 daemonArguments: [], childEnvironment: [:])
    }

    private nonisolated struct Reached: Error {
        let host: String
    }

    /// A pane host that only says it was reached.
    private nonisolated struct NamedHost: AgentPaneHostProviding {
        let name: String
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw Reached(host: name) }
        func sessionFolder(sessionId: String) async throws -> AgentPaneSessionFolder? { nil }
        func putFile(sessionId: String, name: String, data: Data) async throws -> String { "" }
    }

    private func reached(_ host: any AgentPaneHostProviding, session: String) async -> String? {
        do {
            _ = try await host.handshake(sessionId: session)
            return nil
        } catch let reached as Reached {
            return reached.host
        } catch {
            return nil
        }
    }

    /// Counts the files-lane items it runs on a real `BackgroundWork`.
    private nonisolated final class CountingLanes: MayBlockRunner {
        private actor Count {
            var files = 0
            func add() { files += 1 }
        }

        private let lanes = BackgroundWork(label: "test.acpmux-lanes")
        private let count = Count()

        var files: Int {
            get async { await count.files }
        }

        func runFiles<T: Sendable>(_ priority: MayBlockPriority, shutdown: MayBlockShutdown, site: MayBlockCallSite,
                                   _ body: @escaping @Sendable () throws -> T) async throws -> T {
            await count.add()
            return try await lanes.runFiles(priority, shutdown: shutdown, site: site, body)
        }

        func runSystem<T: Sendable>(_ priority: MayBlockPriority, shutdown: MayBlockShutdown, site: MayBlockCallSite,
                                    _ body: @escaping @Sendable () throws -> T) async throws -> T {
            try await lanes.runSystem(priority, shutdown: shutdown, site: site, body)
        }

        func runHostResolution<T: Sendable>(_ priority: MayBlockPriority, shutdown: MayBlockShutdown, site: MayBlockCallSite,
                                            _ body: @escaping @Sendable () throws -> T) async throws -> T {
            try await lanes.runHostResolution(priority, shutdown: shutdown, site: site, body)
        }

        func postFiles(_ priority: MayBlockPriority, shutdown: MayBlockShutdown, site: MayBlockCallSite,
                       _ body: @escaping @Sendable () -> Void) {
            lanes.postFiles(priority, shutdown: shutdown, site: site, body)
        }
    }

    /// A Chief tab whose daemon does not answer attaches by the session it keeps on disk; that check runs on the
    /// files lane, once per tab, and a missing socket is no file check of its own.
    @Test func aKeptSessionIsCheckedOnTheFilesLane() async throws {
        let environment = try Self.environment()
        defer { try? FileManager.default.removeItem(at: environment.home) }
        let kept = "01a1201b-d3c3-7be1-8c40-1f1cbc87b8dc"
        try FileManager.default.createDirectory(at: environment.home.appendingPathComponent("sessions/\(kept)", isDirectory: true),
                                                withIntermediateDirectories: true)
        let lanes = CountingLanes()
        let router = AcpmuxChiefSessionRouter(local: NamedHost(name: "app"), chief: NamedHost(name: "chief"),
                                              chiefEnvironment: environment, parentTag: "optchat-chief:test", work: lanes)

        #expect(await reached(router, session: kept) == "chief")
        #expect(await lanes.files == 1)
        #expect(await reached(router, session: "new-chat") == "app")
        #expect(await lanes.files == 2)
    }

    #if DEBUG
    /// The kept-session check reads the disk on no main thread and no pool thread.
    @Test func theRoutersDiskCheckBlocksNoMainOrPoolThread() async throws {
        let environment = try Self.environment()
        defer { try? FileManager.default.removeItem(at: environment.home) }
        let router = AcpmuxChiefSessionRouter(local: NamedHost(name: "app"), chief: NamedHost(name: "chief"),
                                              chiefEnvironment: environment, parentTag: "optchat-chief:test",
                                              work: BackgroundWork(label: "test.acpmux-lanes"))
        let table = BlockingViolationTable(mode: .record)
        let host = await BlockingViolationTable.$scoped.withValue(table) { await reached(router, session: "s1") }
        await table.flush()

        #expect(host == "app")
        #expect(table.sites.isEmpty, "the router blocked the main thread or the pool: \(table.sites)")
    }

    /// A reconnect with no daemon reads `daemon.pid` (did it crash?) on the pane host's own queue: never a pool
    /// thread, where every task of the app would wait behind a slow disk.
    @Test func aReconnectReadsTheDaemonPidOnTheHostsQueue() async throws {
        let environment = try Self.environment()
        defer { try? FileManager.default.removeItem(at: environment.home) }
        // A live pid: the daemon did not crash, so the reconnect may not start one.
        try String(getpid()).write(to: environment.home.appendingPathComponent("daemon.pid"), atomically: true, encoding: .utf8)
        let host = AcpmuxHost(environment: environment)
        let table = BlockingViolationTable(mode: .record)
        await BlockingViolationTable.$scoped.withValue(table) {
            await #expect(throws: AgentPaneHostError.daemonStopped) {
                _ = try await host.reconnectHandshake(sessionId: nil)
            }
        }
        await table.flush()

        #expect(table.sites.isEmpty, "the pid read blocked the main thread or the pool: \(table.sites)")
    }

    /// The approval banner's line to a daemon that is not running answers nil and checks no file on the main
    /// thread: the connect on the line's queue fails instead.
    @Test func aPersonLineToNoDaemonChecksNoFileOnTheMainThread() async throws {
        let environment = try Self.environment()
        defer { try? FileManager.default.removeItem(at: environment.home) }
        let deadlines = MainDeadlineScheduler(work: MainWorkScheduler(budget: MainFrameBudget()))
        let table = BlockingViolationTable(mode: .record)
        let line = await BlockingViolationTable.$scoped.withValue(table) {
            await AcpmuxPersonLine.open(environment, deadlines: deadlines, deadline: .seconds(5))
        }
        await table.flush()

        #expect(line == nil)
        #expect(table.sites.filter { $0.context == .main }.isEmpty, "the line checked a file on the main thread: \(table.sites)")
    }
    #endif

    /// A proof is made only on the line's queue, for a connection whose server peer was checked: a line that
    /// never connected refuses, and its request is never built.
    @Test func aLineThatNeverConnectedRefusesTheProof() async throws {
        let environment = try Self.environment()
        defer { try? FileManager.default.removeItem(at: environment.home) }
        let line = AcpmuxCheckedLine(environment: environment)
        let built: Bool = await withCheckedContinuation { continuation in
            line.sendPersonProof(nonce: "n", connection: "c", request: { _ in
                continuation.resume(returning: true)
                return Data()
            }, refused: { continuation.resume(returning: false) })
        }
        #expect(!built)
    }
}

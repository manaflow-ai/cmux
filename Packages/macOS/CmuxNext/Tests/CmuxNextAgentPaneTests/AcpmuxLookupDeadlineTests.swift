import CmuxNextCompat
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// no-hangs (2026-11-24): the acpmux lookup's last status call waited with no deadline, and every
/// pane awaited the one shared lookup with none either, so a daemon that never answered (one wedged
/// after a restart) held every pane on "Waiting for the agent service" forever, and the picker's
/// peer list with them. The lookup now has one deadline (``AcpmuxHost/lookupDeadline``) passed
/// down to each status call; past it the lookup ends as ``AgentPaneHostError/timedOut`` (stopping
/// or starting nothing), leaves `inFlight`, and the next ask looks up afresh.
@Suite(.timeLimit(.minutes(1))) struct AcpmuxLookupDeadlineTests {
    private typealias SlowDaemon = AcpmuxSlowDaemonTests.SlowDaemon

    private static func attachedEnvironment() throws -> (AcpmuxEnvironment, URL) {
        let root = URL(fileURLWithPath: "/tmp/ald-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let environment = AcpmuxEnvironment(executable: try AcpmuxSlowDaemonTests.ownExecutable(), home: home,
                                            socketPath: home.appendingPathComponent("s.sock").path,
                                            daemonArguments: [], childEnvironment: [:]).attached(to: home)
        return (environment, root)
    }

    private static func isTimedOut(_ error: any Error) -> Bool {
        if case AgentPaneHostError.timedOut = error { return true }
        return false
    }

    /// Before: the last of the status tries waited for an answer that never came.
    @Test func theLastStatusTryEndsAtTheLookupsDeadline() async throws {
        let (environment, root) = try Self.attachedEnvironment()
        defer { try? FileManager.default.removeItem(at: root) }
        let daemon = try SlowDaemon(socketPath: environment.socketPath, home: environment.home.path, statusDelay: .seconds(3600))
        defer { daemon.stop() }

        let started = ContinuousClock.now
        await #expect(throws: AgentPaneDeadlineExceeded.self) {
            _ = try await AcpmuxHost.lookupStatus(socketPath: environment.socketPath,
                                                  attempts: [.milliseconds(100), .milliseconds(100)],
                                                  until: started + .milliseconds(600))
        }
        #expect(ContinuousClock.now - started < .seconds(10))
        #expect(daemon.methods.filter { $0 == "_acpmux/status" }.count >= 3, "the tries were not asked again")
    }

    /// The whole handshake against a daemon that never answers ends as timedOut, never stops it,
    /// and the reconnect after it runs a lookup of its own (the shared one was dropped).
    @Test func aHandshakeOnASilentDaemonEndsTimedOutAndTheNextAsksAgain() async throws {
        let (environment, root) = try Self.attachedEnvironment()
        defer { try? FileManager.default.removeItem(at: root) }
        let daemon = try SlowDaemon(socketPath: environment.socketPath, home: environment.home.path, statusDelay: .seconds(3600))
        defer { daemon.stop() }
        let host = AcpmuxHost(daemons: AcpmuxLocalDaemons(), resolve: { environment },
                              lookupDeadline: .seconds(2), lookupGrace: .milliseconds(200))

        let started = ContinuousClock.now
        do {
            _ = try await host.reconnectHandshake(sessionId: "s")
            Issue.record("a daemon that answers nothing gave an endpoint")
        } catch {
            #expect(Self.isTimedOut(error), "ended as \(error), not timedOut")
        }
        #expect(ContinuousClock.now - started < .seconds(10))
        await host.lookupSettled()
        let asked = daemon.methods.filter { $0 == "_acpmux/status" }.count

        do {
            _ = try await host.reconnectHandshake(sessionId: "s")
            Issue.record("a daemon that answers nothing gave an endpoint")
        } catch {
            #expect(Self.isTimedOut(error), "ended as \(error), not timedOut")
        }
        #expect(daemon.methods.filter { $0 == "_acpmux/status" }.count > asked, "the second handshake joined the first lookup")
    }

    /// The picker's peer list shares the lookup's deadline: before, it waited on a silent daemon forever.
    @Test func chatPeersOnASilentDaemonEndsTimedOut() async throws {
        let (environment, root) = try Self.attachedEnvironment()
        defer { try? FileManager.default.removeItem(at: root) }
        let daemon = try SlowDaemon(socketPath: environment.socketPath, home: environment.home.path, statusDelay: .seconds(3600))
        defer { daemon.stop() }
        let host = AcpmuxHost(daemons: AcpmuxLocalDaemons(), resolve: { environment },
                              lookupDeadline: .seconds(2), lookupGrace: .milliseconds(200))

        let started = ContinuousClock.now
        do {
            _ = try await host.chatPeers()
            Issue.record("a daemon that answers nothing listed peers")
        } catch {
            #expect(Self.isTimedOut(error), "ended as \(error), not timedOut")
        }
        #expect(ContinuousClock.now - started < .seconds(10))
    }

    /// A lookup step that ignores its deadline (the injected one waits for a gate) is dropped once
    /// overdue: the waiting handshake ends as timedOut, and the next one starts a fresh lookup
    /// instead of joining the stuck one.
    @Test func anOverdueLookupIsDroppedAndTheNextHandshakeLooksUpAgain() async throws {
        let (environment, root) = try Self.attachedEnvironment()
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = Gate()
        defer { gate.open() }
        let runs = Mutex(0)
        let host = AcpmuxHost(daemons: AcpmuxLocalDaemons(), resolve: { environment },
                              lookup: { _, _ in
                                  let run = runs.withLock { runs in
                                      runs += 1
                                      return runs
                                  }
                                  if run == 1 { await gate.wait() }
                                  return AcpmuxWebEndpoint(url: URL(fileURLWithPath: "/ws/\(run)"), token: "token-\(run)")
                              },
                              lookupDeadline: .milliseconds(200), lookupGrace: .milliseconds(100))

        do {
            _ = try await host.handshake(sessionId: "s")
            Issue.record("the stuck lookup gave an endpoint")
        } catch {
            #expect(Self.isTimedOut(error), "ended as \(error), not timedOut")
        }
        await host.lookupSettled()
        let second = try await host.handshake(sessionId: "s")
        #expect(second.connection?.dashboardToken == "token-2")
        #expect(runs.withLock { $0 } == 2)
    }

    /// One caller's deadline ends only its own wait: the shared lookup goes on and another caller
    /// still gets its value.
    @Test func aCallersDeadlineDoesNotEndTheSharedLookup() async throws {
        let gate = Gate()
        // task-owner: the shared work; ends when the gate opens below
        let shared = Task<Int, any Error> {
            await gate.wait()
            return 7
        }
        // task-owner: the survivor's wait; awaited below
        let survivor = Task { try await AcpmuxSharedWait.value(of: shared) }
        await #expect(throws: AgentPaneDeadlineExceeded.self) {
            _ = try await AcpmuxSharedWait.value(of: shared, until: .now + .milliseconds(100))
        }
        #expect(!shared.isCancelled)
        gate.open()
        #expect(try await survivor.value == 7)
    }

    /// Opens once; every wait before or after ends then.
    private nonisolated final class Gate: Sendable {
        private let state = Mutex<(open: Bool, waiting: [CheckedContinuation<Void, Never>])>((false, []))

        func wait() async {
            await withCheckedContinuation { continuation in
                let resumeNow = state.withLock { state -> Bool in
                    if state.open { return true }
                    state.waiting.append(continuation)
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        }

        func open() {
            let waiting = state.withLock { state -> [CheckedContinuation<Void, Never>] in
                state.open = true
                defer { state.waiting = [] }
                return state.waiting
            }
            for continuation in waiting { continuation.resume() }
        }
    }
}

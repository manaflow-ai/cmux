import CmuxNextServerHelper
import Foundation
import ServiceManagement
import Testing
@testable import CmuxNextApp

/// Stop Serving reverts the helper's fixes, then removes the LaunchAgent and
/// the helper; it is a no-op when nothing is registered (server.md 4.4, 9.4).
@MainActor
@Suite struct ServerStopServingTests {
    final class Log {
        var entries: [String] = []
        var revertFailures: [ServerFix: ServerHelperClient.Failure] = [:]
    }

    final class FakeJob {
        let name: String
        let log: Log
        var status: SMAppService.Status
        var failUnregister = false

        init(_ name: String, _ status: SMAppService.Status, log: Log) {
            self.name = name
            self.status = status
            self.log = log
        }

        var registration: ServerServiceRegistration {
            // Strong captures: a job made inline must outlive the run.
            ServerServiceRegistration(status: { self.status }, unregister: {
                self.log.entries.append("unregister \(self.name)")
                if self.failUnregister { throw CocoaError(.fileWriteNoPermission) }
                self.status = .notRegistered
            })
        }
    }

    private func stop(agent: FakeJob?, helper: FakeJob?, log: Log, gate: ServerFixGate = ServerFixGate()) -> ServerStopServing {
        ServerStopServing(agent: agent?.registration, helper: helper?.registration,
                          revert: { (fix: ServerFix) async throws(ServerHelperClient.Failure) in
                              log.entries.append("revert \(fix.rawValue)")
                              if let failure = log.revertFailures[fix] { throw failure }
                          }, gate: gate)
    }

    @Test func revertsEveryFixThenRemovesTheAgentAndTheHelper() async throws {
        let log = Log()
        // A fix that was never applied answers "nothing to revert": not an error.
        log.revertFailures[.wakeOnNetworkOn] = .refused(ServerHelperService.nothingToRevert)
        let agent = FakeJob("agent", .enabled, log: log)
        let helper = FakeJob("helper", .enabled, log: log)
        try await stop(agent: agent, helper: helper, log: log).run()
        #expect(log.entries == ServerFix.allCases.map { "revert \($0.rawValue)" } + ["unregister agent", "unregister helper"])
        #expect(agent.status == .notRegistered)
        #expect(helper.status == .notRegistered)
    }

    @Test func nothingRegisteredIsANoOp() async throws {
        let log = Log()
        try await stop(agent: FakeJob("agent", .notRegistered, log: log),
                       helper: FakeJob("helper", .notRegistered, log: log), log: log).run()
        try await stop(agent: nil, helper: nil, log: log).run()
        #expect(log.entries.isEmpty)
    }

    @Test func runningTwiceIsIdempotent() async throws {
        let log = Log()
        let agent = FakeJob("agent", .enabled, log: log)
        let helper = FakeJob("helper", .enabled, log: log)
        let action = stop(agent: agent, helper: helper, log: log)
        try await action.run()
        let first = log.entries
        #expect(!first.isEmpty)
        try await action.run()
        #expect(log.entries == first)
    }

    /// The helper cannot run until approved, and the app cannot read what it
    /// recorded: the values count as changed, so the helper stays.
    @Test func aHelperAwaitingApprovalIsKeptAndTheUserIsAskedToApprove() async {
        let log = Log()
        let agent = FakeJob("agent", .enabled, log: log)
        let helper = FakeJob("helper", .requiresApproval, log: log)
        await #expect(throws: ServerStopServing.Failure.revert(ServerHealthFixer.reject(for: .requiresApproval))) {
            try await stop(agent: agent, helper: helper, log: log).run()
        }
        #expect(log.entries == ["unregister agent"])
        #expect(helper.status == .requiresApproval)
    }

    /// Stop Serving while a Fix is between helper calls: the fix's current
    /// apply lands first, the cancelled fix starts no more, then every fix
    /// is reverted.
    @Test func aRunningFixFinishesItsStepBeforeTheReverts() async throws {
        let log = Log()
        let gate = ServerFixGate()
        final class Hold { var step: CheckedContinuation<Void, Never>? }
        let hold = Hold()
        let fixer = ServerHealthFixer(run: { (fix: ServerFix, _: Bool) async throws(ServerHelperClient.Failure) in
            log.entries.append("apply \(fix.rawValue)")
            if fix == .systemSleepOffOnAC { await withCheckedContinuation { hold.step = $0 } }
        }, gate: gate)
        let fixing = Task { await fixer.fix(.sleepEnabled) }
        #expect(await eventually { hold.step != nil })
        let helper = FakeJob("helper", .enabled, log: log)
        let stopping = Task { try await stop(agent: nil, helper: helper, log: log, gate: gate).run() }
        fixing.cancel()
        for _ in 0..<20 { await Task.yield() }
        #expect(!log.entries.contains { $0.hasPrefix("revert") }, "the reverts wait for the running apply")
        try #require(hold.step).resume()
        _ = await fixing.value
        try await stopping.value
        #expect(log.entries == ["apply \(ServerFix.systemSleepOffOnAC.rawValue)"]
            + ServerFix.allCases.map { "revert \($0.rawValue)" } + ["unregister helper"])
    }

    @Test func aFailedRevertKeepsTheHelperSoTheUserCanTryAgain() async {
        let log = Log()
        log.revertFailures[.autoRestartOn] = .refused("pmset exited 1")
        let agent = FakeJob("agent", .enabled, log: log)
        let helper = FakeJob("helper", .enabled, log: log)
        await #expect(throws: ServerStopServing.Failure.revert(ServerHealthFixer.reject(for: .refused("pmset exited 1")))) {
            try await stop(agent: agent, helper: helper, log: log).run()
        }
        #expect(log.entries.filter { $0.hasPrefix("revert") }.count == ServerFix.allCases.count, "every other fix is still reverted")
        #expect(agent.status == .notRegistered)
        #expect(helper.status == .enabled)
    }

    @Test func anUnregisterFailureIsReported() async {
        let log = Log()
        let agent = FakeJob("agent", .enabled, log: log)
        agent.failUnregister = true
        await #expect(throws: ServerStopServing.Failure.self) {
            try await stop(agent: agent, helper: nil, log: log).run()
        }
    }
}

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

    private func stop(agent: FakeJob?, helper: FakeJob?, log: Log) -> ServerStopServing {
        ServerStopServing(agent: agent?.registration, helper: helper?.registration,
                          revert: { (fix: ServerFix) async throws(ServerHelperClient.Failure) in
                              log.entries.append("revert \(fix.rawValue)")
                              if let failure = log.revertFailures[fix] { throw failure }
                          })
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
        try await action.run()
        #expect(log.entries == first)
    }

    @Test func aHelperAwaitingApprovalIsRemovedWithoutReverts() async throws {
        let log = Log()
        let helper = FakeJob("helper", .requiresApproval, log: log)
        try await stop(agent: nil, helper: helper, log: log).run()
        #expect(log.entries == ["unregister helper"])
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

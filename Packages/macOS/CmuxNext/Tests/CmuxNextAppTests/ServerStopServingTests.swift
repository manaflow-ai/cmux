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

    /// A ledger in a fresh temp file; `fixes` are recorded as applied.
    static func ledger(_ fixes: [ServerFix] = []) async throws -> ServerFixLedger {
        let ledger = ServerFixLedger(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-fix-ledger-\(UUID().uuidString)/ledger.json"))
        for fix in fixes { try await ledger.record(fix) }
        return ledger
    }

    private func stop(agent: FakeJob?, helper: FakeJob?, log: Log, ledger: ServerFixLedger,
                      gate: ServerFixGate = ServerFixGate()) -> ServerStopServing {
        ServerStopServing(agent: agent?.registration, helper: helper?.registration,
                          revert: { (fix: ServerFix) async throws(ServerHelperClient.Failure) in
                              log.entries.append("revert \(fix.rawValue)")
                              if let failure = log.revertFailures[fix] { throw failure }
                          }, gate: gate, ledger: ledger)
    }

    @Test func revertsEveryFixThenRemovesTheAgentAndTheHelper() async throws {
        let log = Log()
        // A fix that was never applied answers "nothing to revert": not an error.
        log.revertFailures[.wakeOnNetworkOn] = .refused(ServerHelperService.nothingToRevert)
        let agent = FakeJob("agent", .enabled, log: log)
        let helper = FakeJob("helper", .enabled, log: log)
        let ledger = try await Self.ledger(ServerFix.allCases)
        try await stop(agent: agent, helper: helper, log: log, ledger: ledger).run()
        #expect(log.entries == ServerFix.allCases.map { "revert \($0.rawValue)" } + ["unregister agent", "unregister helper"])
        #expect(agent.status == .notRegistered)
        #expect(helper.status == .notRegistered)
        #expect(await ledger.load() == .fixes([]), "each revert clears its entry")
    }

    @Test func nothingRegisteredIsANoOp() async throws {
        let log = Log()
        let ledger = try await Self.ledger()
        try await stop(agent: FakeJob("agent", .notRegistered, log: log),
                       helper: FakeJob("helper", .notRegistered, log: log), log: log, ledger: ledger).run()
        try await stop(agent: nil, helper: nil, log: log, ledger: ledger).run()
        #expect(log.entries.isEmpty)
    }

    @Test func runningTwiceIsIdempotent() async throws {
        let log = Log()
        let agent = FakeJob("agent", .enabled, log: log)
        let helper = FakeJob("helper", .enabled, log: log)
        let action = stop(agent: agent, helper: helper, log: log, ledger: try await Self.ledger([.autoRestartOn]))
        try await action.run()
        let first = log.entries
        #expect(!first.isEmpty)
        try await action.run()
        #expect(log.entries == first)
    }

    /// Recorded fixes and a helper awaiting approval: only that helper can
    /// restore the values, so it stays and the user is asked to approve.
    @Test func aRecordedFixKeepsAHelperAwaitingApproval() async throws {
        let log = Log()
        let agent = FakeJob("agent", .enabled, log: log)
        let helper = FakeJob("helper", .requiresApproval, log: log)
        let ledger = try await Self.ledger([.systemSleepOffOnAC])
        await #expect(throws: ServerStopServing.Failure.revert(ServerHealthFixer.reject(for: .requiresApproval))) {
            try await stop(agent: agent, helper: helper, log: log, ledger: ledger).run()
        }
        #expect(log.entries == ["unregister agent"])
        #expect(helper.status == .requiresApproval)
        #expect(await ledger.load() == .fixes([.systemSleepOffOnAC]))
    }

    /// A helper that was never approved never ran: stopping needs no approval.
    @Test func aNeverApprovedHelperWithAnEmptyLedgerStopsWithoutAPrompt() async throws {
        let log = Log()
        let agent = FakeJob("agent", .enabled, log: log)
        let helper = FakeJob("helper", .requiresApproval, log: log)
        try await stop(agent: agent, helper: helper, log: log, ledger: try await Self.ledger()).run()
        #expect(log.entries == ["unregister agent", "unregister helper"])
        #expect(helper.status == .notRegistered)
    }

    /// A ledger that cannot be read counts as "every fix may be applied".
    @Test func aBrokenLedgerIsTreatedAsNotEmpty() async throws {
        let ledger = try await Self.ledger()
        try FileManager.default.createDirectory(at: ledger.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: ledger.url)
        #expect(await ledger.load() == .unknown)

        let waiting = Log()
        await #expect(throws: ServerStopServing.Failure.self) {
            try await stop(agent: nil, helper: FakeJob("helper", .requiresApproval, log: waiting), log: waiting, ledger: ledger).run()
        }
        #expect(waiting.entries.isEmpty, "kept, no revert possible")

        let log = Log()
        try await stop(agent: nil, helper: FakeJob("helper", .enabled, log: log), log: log, ledger: ledger).run()
        #expect(log.entries == ServerFix.allCases.map { "revert \($0.rawValue)" } + ["unregister helper"])
        #expect(await ledger.load() == .fixes([]), "a full revert leaves an empty ledger")
    }

    /// Stop Serving while a Fix is between helper calls: the fix's current
    /// apply lands first, the cancelled fix starts no more, then every fix
    /// is reverted.
    @Test func aRunningFixFinishesItsStepBeforeTheReverts() async throws {
        let log = Log()
        let gate = ServerFixGate()
        let ledger = try await Self.ledger()
        final class Hold { var step: CheckedContinuation<Void, Never>? }
        let hold = Hold()
        let fixer = ServerHealthFixer(run: { (fix: ServerFix, _: Bool, willCall: @escaping @MainActor () async throws -> Void) async throws(ServerHelperClient.Failure) in
            do { try await willCall() } catch { throw .failed("\(error)") }
            log.entries.append("apply \(fix.rawValue)")
            if fix == .systemSleepOffOnAC { await withCheckedContinuation { hold.step = $0 } }
        }, gate: gate, ledger: ledger)
        let fixing = Task { await fixer.fix(.sleepEnabled) }
        #expect(await eventually { hold.step != nil })
        let helper = FakeJob("helper", .enabled, log: log)
        let stopping = Task { try await stop(agent: nil, helper: helper, log: log, ledger: ledger, gate: gate).run() }
        fixing.cancel()
        for _ in 0..<20 { await Task.yield() }
        #expect(!log.entries.contains { $0.hasPrefix("revert") }, "the reverts wait for the running apply")
        try #require(hold.step).resume()
        #expect(await fixing.value == ServerHealthFixer.cancelled, "a cancelled fix is no success")
        try await stopping.value
        #expect(log.entries == ["apply \(ServerFix.systemSleepOffOnAC.rawValue)"]
            + ServerFix.allCases.map { "revert \($0.rawValue)" } + ["unregister helper"])
        #expect(await ledger.load() == .fixes([]))
    }

    @Test func aFailedRevertKeepsTheHelperSoTheUserCanTryAgain() async throws {
        let log = Log()
        let ledger = try await Self.ledger(ServerFix.allCases)
        log.revertFailures[.autoRestartOn] = .refused("pmset exited 1")
        let agent = FakeJob("agent", .enabled, log: log)
        let helper = FakeJob("helper", .enabled, log: log)
        await #expect(throws: ServerStopServing.Failure.revert(ServerHealthFixer.reject(for: .refused("pmset exited 1")))) {
            try await stop(agent: agent, helper: helper, log: log, ledger: ledger).run()
        }
        #expect(await ledger.load() == .fixes([.autoRestartOn]), "only the failed revert stays recorded")
        #expect(log.entries.filter { $0.hasPrefix("revert") }.count == ServerFix.allCases.count, "every other fix is still reverted")
        #expect(agent.status == .notRegistered)
        #expect(helper.status == .enabled)
    }

    /// An enabled helper reverts every allowlisted fix even when the ledger
    /// is empty (it may have been lost); no approval is asked.
    @Test func anEnabledHelperRevertsEverythingEvenWithAnEmptyLedger() async throws {
        let log = Log()
        try await stop(agent: nil, helper: FakeJob("helper", .enabled, log: log), log: log, ledger: try await Self.ledger()).run()
        #expect(log.entries == ServerFix.allCases.map { "revert \($0.rawValue)" } + ["unregister helper"])
    }

    /// A Fix that queued behind Stop Serving runs only after the helper is gone.
    @Test func theGateIsHeldUntilTheHelperIsRemoved() async throws {
        let log = Log()
        let gate = ServerFixGate()
        let ledger = try await Self.ledger()
        final class Hold { var step: CheckedContinuation<Void, Never>? }
        let hold = Hold()
        let helper = FakeJob("helper", .enabled, log: log)
        let job = helper.registration
        let slowHelper = ServerServiceRegistration(status: job.status, unregister: {
            await withCheckedContinuation { hold.step = $0 }
            try await job.unregister()
        })
        let stopping = Task {
            try await ServerStopServing(agent: nil, helper: slowHelper, revert: { (_: ServerFix) async throws(ServerHelperClient.Failure) in },
                                        gate: gate, ledger: ledger).run()
        }
        #expect(await eventually { hold.step != nil })
        let fixer = ServerHealthFixer(run: { (fix: ServerFix, _: Bool, willCall: @escaping @MainActor () async throws -> Void) async throws(ServerHelperClient.Failure) in
            do { try await willCall() } catch { throw .failed("\(error)") }
            log.entries.append("apply \(fix.rawValue)")
        }, gate: gate, ledger: ledger)
        let fixing = Task { await fixer.fix(.noAutoRestart) }
        for _ in 0..<20 { await Task.yield() }
        #expect(!log.entries.contains { $0.hasPrefix("apply") }, "the fix waits for Stop Serving")
        try #require(hold.step).resume()
        try await stopping.value
        _ = await fixing.value
        #expect(log.entries == ["unregister helper", "apply \(ServerFix.autoRestartOn.rawValue)"])
    }

    /// A Fix that stops at approval never reached the helper, so it records
    /// nothing, and stopping then needs no approval.
    @Test func aFixAwaitingApprovalRecordsNothingAndStopNeedsNoPrompt() async throws {
        let log = Log()
        let ledger = try await Self.ledger()
        let fixer = ServerHealthFixer(run: { (_: ServerFix, _: Bool, _: @escaping @MainActor () async throws -> Void)
            async throws(ServerHelperClient.Failure) in
            throw .requiresApproval
        }, gate: ServerFixGate(), ledger: ledger)
        #expect(await fixer.fix(.sleepEnabled) == ServerHealthFixer.reject(for: .requiresApproval))
        #expect(await ledger.load() == .fixes([]))
        let helper = FakeJob("helper", .requiresApproval, log: log)
        try await stop(agent: FakeJob("agent", .enabled, log: log), helper: helper, log: log, ledger: ledger).run()
        #expect(log.entries == ["unregister agent", "unregister helper"])
    }

    /// Recorded fixes with no helper registered: nothing can restore them now,
    /// so the entries stay, the agent goes, and the user is told.
    @Test func recordedFixesWithoutAHelperAreReportedAndKept() async throws {
        let log = Log()
        let ledger = try await Self.ledger([.autoRestartOn])
        let agent = FakeJob("agent", .enabled, log: log)
        await #expect(throws: ServerStopServing.Failure.notRestored) {
            try await stop(agent: agent, helper: FakeJob("helper", .notRegistered, log: log), log: log, ledger: ledger).run()
        }
        await #expect(throws: ServerStopServing.Failure.notRestored) {
            try await stop(agent: nil, helper: nil, log: log, ledger: ledger).run()
        }
        #expect(log.entries == ["unregister agent"])
        #expect(await ledger.load() == .fixes([.autoRestartOn]))
        #expect(!ServerStopServing.Failure.notRestored.message.isEmpty)
    }

    /// A ledger naming a fix this build does not know is never emptied by it.
    @Test func aForeignLedgerKeepsTheIdsThisBuildCannotRevert() async throws {
        let ledger = try await Self.ledger()
        try FileManager.default.createDirectory(at: ledger.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"version": 1, "fixes": {"pmset.future.fix": 1, "pmset.autorestart.1": 2}}"#.utf8).write(to: ledger.url)
        let log = Log()
        try await stop(agent: nil, helper: FakeJob("helper", .enabled, log: log), log: log, ledger: ledger).run()
        #expect(log.entries == ServerFix.allCases.map { "revert \($0.rawValue)" } + ["unregister helper"])
        #expect(await ledger.load() == .foreign)
        let left = try JSONSerialization.jsonObject(with: Data(contentsOf: ledger.url)) as? [String: Any]
        #expect((left?["fixes"] as? [String: Any]).map { Set($0.keys) } == ["pmset.future.fix"])
    }

    @Test func anUnregisterFailureIsReported() async throws {
        let log = Log()
        let ledger = try await Self.ledger()
        let agent = FakeJob("agent", .enabled, log: log)
        agent.failUnregister = true
        await #expect(throws: ServerStopServing.Failure.self) {
            try await stop(agent: agent, helper: nil, log: log, ledger: ledger).run()
        }
    }
}
